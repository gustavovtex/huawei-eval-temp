# Multi-model spec eval — strategy summary

Comparing N models on the same agentic-coding spec, anchored on the code that actually
shipped. Full detail in [`spec-eval-design.md`](../spec-eval-design.md).

---

## 1. The question and the method

**Question:** given the `SPEC.md` of an already-merged PR, which model reimplements the
change best — and at what cost in time?

**Method:** roll the repository back to the commit immediately before the PR, hand the
spec to each model, and compare the result against the diff that actually went to
production.

The principle that governs everything: **gate before judge.** An LLM judging is
unreliable exactly where a machine is infallible — does it compile? do the tests pass? So
scoring has two tiers, and the judge never decides what a compiler decides.

| Tier | Question | Mechanism | Cost |
|---|---|---|---|
| **0 — Gate** | Did it break what already worked? | `verify.sh`, the repo's own suite | free, fast, indisputable |
| **1 — Judge** | Among those that work, which is better engineering? | Opus 5 + rubric, anchored on the reference diff | expensive |

Whatever fails Tier 0 scores zero and never reaches the judge. That cuts judging spend in
proportion to the failure rate, and eliminates the failure mode where a judge confidently
praises code that does not run.

---

## 2. Pipeline

| Step | Script | What it produces |
|---|---|---|
| PR → spec | `extract-spec.sh` | `base.sha`, `SPEC.md`, `base-repo/`, reference patches and tars |
| Preconditions + gate | `derive-tests.sh` | `tests.json`, `verify.sh` |
| Rubric calibration | `calibrate.sh` | scores the reference against itself |
| Generation | `sweep.sh` → `run-one.sh` | `diff.patch`, `transcript.jsonl`, `metrics.json`, `verify.json` |
| Generation (alternate harness) | `sweep-opencode.sh` → `run-one-opencode.sh` | same, with `harness: "opencode"` |
| Blinding | `blind.sh` | `anon/<spec>/candidate-XX/` + a mapping the judge never reads |
| Judging | `judge.py` | `judged/<spec>/*.median.json` |
| Inspection | `status.sh` | per-run state: passed, failed, stalled, still running |
| Re-gating | `regate.sh` | re-runs Tier 0 from the saved `diff.patch`, without re-invoking a model |
| Reporting | `report.py` | deanonymises and aggregates — the tables in §5 |

Generation and judging write to separate trees (`runs/` and `judged/`), so a revised
rubric can be re-judged **without paying for generation again** — which matters a lot,
because rubrics take iteration.

---

## 3. Design decisions that hold the result up

**Constant harness.** Every model runs through the same binary (`cursor-agent`), with the
same system prompt, the same tool set and the same turn cap. Using each vendor's own CLI
would compare *harnesses*, not models, and there is no statistical correction for that.

**The reference is the anchor, not the ceiling.** The diff that shipped enters the rubric
worth **4, not 5** — it is what an engineer delivered under a deadline, not the optimum.
Without that headroom the eval is capped at the status quo.

**Deduct for behaviour, never for approach.** A candidate that reaches the same observable
result by another route is correct, whatever its file layout or decomposition. This is
explicit in the judge's prompt because it is the default failure mode of
reference-anchored judging.

**k = 3 repetitions per model.** One run measures luck. Report the distribution, not the
mean — `pass@k` (capability ceiling) kept separate from `pass^k` (reliability).

**Generation is serial, on purpose.** Time per attempt is a first-class metric; concurrent
runs contend for CPU, disk and network, and wall clock stops comparing models. Only
judging is parallel (`judge.py --jobs`), because it happens afterwards and feeds no model
metric.

**Time split by phase.** `generate_wall_clock_s` (the agent) and `verify_wall_clock_s`
(install + suite) are kept apart: a slow install would make a model look slow.

**Not passing has more than one meaning, and the report distinguishes three.** This was
the most consequential decision after the eval outgrew a single harness, because treating
everything as "failed" attributes to the model things that are not its doing:

| Outcome | Real example in this eval | Counted in the rate? |
|---|---|---|
| **Failure** | 21 of the candidate's own tests failing | yes — it is a defect |
| **Interrupted** | provider content filter blocking the response at step 71 | yes, but named — the model worked, something external ended it |
| **Not measured** | AWS IAM denying `CreateInference`: zero steps | **no** — it would measure the infrastructure, not the candidate |

Without that separation the report would say `gpt-5.6-terra: 0/3` about a model that was
never invoked.

**Silence has a limit.** Generation had no timeout at all, and one run hung at a step
boundary waiting on a gateway response that never returned nor expired: it sat 7980s
without writing a byte, and the process outlived its own shell by more than two hours. The
guard is **stall detection, not a total timeout** — an absolute cap would have to be
enormous not to kill a legitimate run, since the slowest run that passed took 6103s. With
no growth in `transcript.jsonl` for 30 minutes, the agent tree is killed,
`termination_reason` becomes `stalled`, and capture happens anyway: a partial diff from a
stalled run is data.

**An attempt is not a repetition.** When a run is discarded and regenerated, the discarded
attempt goes to `stalled-runs/` and the report counts it as **reliability cost of the
route**, outside `pass@k` — where it would count the same repetition twice. That is what
stops regenerating a failure from erasing it from the record.

---

## 4. Sweep results

**27 runs**: 5 models × 3 repetitions via `cursor-agent`, plus 4 routes × 3 repetitions
via `opencode`. Effort `high` throughout, serial generation.

### Via `cursor-agent`

| Model (via `cursor-agent`) | r0 | r1 | r2 | median | turns | lines changed | prompt tok | output tok | n |
|---|---:|---:|---:|---:|---:|---|---:|---:|---|
| `gpt-5.6-terra-high` | 424 | 342 | **6113** | 424 | 235 | 547 / 506 / 511 | 144,360 | 20,927.5 | 2/3 |
| `glm-5.2-high` | 475 | 631 | 652 | 631 | 302 | 945 / 1285 / 1501 | 159,012 | 38,122 | 3/3 |
| `gemini-3.1-pro` | 500 | 577 | 848 | 577 | 172 | 311 / 265 / 607 | **1,024,606** | 14,119 | 3/3 |
| `cursor-grok-4.6-high` | 876 | 1023 | 839 | 876 | 346 | 1258 / 1242 / 1219 | 380,638 | 53,174 | 3/3 |
| `claude-sonnet-5-thinking-high` | 1083 | 1146 | 1389 | 1146 | 301 | 1360 / 1335 / 1394 | 375,260 | **90,367** | 1/3 |

**No model in this table appears in the next one, and vice versa.** The
`gpt-5.6-terra-high` here and the `amazon-bedrock/openai.gpt-5.6-terra` in the following
table are distinct deployments, reached through distinct harnesses — similar names, rows
that do not correspond.

Time in seconds, as measured by the sweep (it includes roughly 11s of worktree setup and
capture per run, so it sits above the `generate_wall_clock_s` that `report.py` shows).
`turns`, `prompt tok` and `output tok` are medians across repetitions.

**`lines changed` changed definition in this revision.** It used to be the total line
count of the `.patch` file, which includes context and hunk headers — `gpt-5.6-terra-high`
r0 showed 785 when it changes 547. It is now added + removed per `git apply --numstat`,
the same definition in both tables.

**`prompt tok` is `inputTokens + cacheWriteTokens`, summed on purpose.** Providers account
for the prompt in different fields: Sonnet and Terra report `input`≈0 with a high
`cacheWrite`, the other three the reverse. In isolation neither field compares — they vary
by four orders of magnitude as an accounting artefact. The sum lands in a plausible
magnitude for all of them.

**The `n` column is how many of the 3 repetitions have trustworthy token counts**, and the
medians use only those. `total` and `cacheRead` are deliberately left out of the table:
`cacheRead` dominates the total (5M to 19M, against 150k–1M of prompt) and nothing
validates it — on Sonnet it varies 19M / 340k / 2.9M across repetitions, tracking the
segmentation. Ranking by it would rank by how much context each one re-read, with a wrong
number in 3 of the 15 runs.

### Via `opencode` — four routes

`opencode` entered because `cursor-agent` **does not offer** `glm-5.2` in that deployment,
and then grew to four routes. Here the harness is constant across the rows: same binary,
same preamble, same worktree. What varies is model and gateway.

| Route (via `opencode`) | k | r0 / r1 / r2 | steps | lines changed | prompt tok | output tok | reasoning | n |
|---|---:|---|---:|---|---:|---:|---:|---|
| `amazon-bedrock/anthropic.claude-sonnet-5` | 3 | 1653 / 1713 / 1743 | 172 | 1473 / 1542 / 1534 | 346,410 | **117,288** | 0 | 3/3 |
| `huawei-modelarts/glm-5.2` | 3 | 1766 / 3096 / 2494 | 183 | 1211 / 1319 / 1577 | **634,427** | 34,395 | 5,691 | 3/3 |
| `vtex-glm/huawei/glm-5.2` | 3 | 3215 / 2675 / 1473 | 184 | 1532 / 1551 / 509 | 347,936 | 36,459 | 4,753 | 3/3 |
| `amazon-bedrock/openai.gpt-5.6-terra` | **0** | — | — | — | — | — | — | 0/3 |

Time is `generate_wall_clock_s`. `steps`, tokens and `reasoning` are medians.
**`steps` are model round-trips, not tool calls** — `report.py` shows tool calls in its
`turns` column, and the two differ by 1 or 2 per route. They are not interchangeable with
the `turns` in the `cursor-agent` table, which counts `tool_call` events.

**The `n` column here is not the same as in the previous table.** There it counts
repetitions whose reported consumption can account for their own diff — a check only
`run-one.sh` performs. `run-one-opencode.sh` does not compute it, so here `n` counts
tokens *loaded*, not *verified*, and reads `3/3` even where the same check might fail.

**`openai.gpt-5.6-terra` on Bedrock produced no data at all.** All three repetitions died
in about 180s with the same response:

```
User: arn:aws:sts::…assumed-role/AWSReservedSSO_SWE_… is not authorized to perform:
bedrock-mantle:CreateInference … because no identity-based policy allows the action
```

Zero steps, zero tokens. It is an IAM permission on the SSO role, not harness
configuration. Those three rows stay **outside the denominator** — counting them as 0/3
would say the model failed, when it was never called.

**`opencode` exposes two fields `cursor-agent` does not have:** `reasoning` and cost — the
latter arriving as zero on every route, which is why cost per approved solution remains
uncomputable. `reasoning` separates GLM from Sonnet cleanly: 5,691 and 4,753 tokens on the
two GLM routes, **exactly 0** across the three Sonnet-on-Bedrock repetitions.

**Prompt accounting inverts between gateways.** Huawei and vtex-glm report everything in
`input` with `cacheWrite` at zero; Bedrock reports `input`≈344 and puts 346k in
`cacheWrite`. It is the same artefact seen on `cursor-agent`, and the reason `prompt tok`
is always the sum of both fields. `cacheRead` stays out of the table: it dominates the
total (10M to 38M) and nothing validates it.

### Takeaways

**The `gpt-5.6-terra-high` r2 outlier is the most important finding.** 6113s against 424s
and 342s — 14× r0, 18× r1 — with 235 turns (r0 did 238) and an almost identical diff (511
against 547 lines). It did not do more work; it sat idle. This is why the distribution is
reported rather than the mean: its mean lands at **2293s** and describes a model that does
not exist. The median, 424s, describes what it is.

**Internal consistency varies a lot between models.** `gpt-5.6-terra-high` delivers
547/506/511 lines, practically deterministic; `glm-5.2-high` varies 945→1501 (+59%).
`gemini-3.1-pro` produces the smallest diff and the fewest turns across all three
repetitions.

**`gemini-3.1-pro` reads a lot and delivers little.** 1.02M of prompt — **6.4× the GLM** —
to produce the smallest diff (311/265/607) with the fewest turns (172). It is the sharpest
contrast in the table, and it did not show while tokens were left out.

**Sonnet 5 is the slowest and the most voluminous**, but the tokens do not confirm that —
they merely fail to contradict it. The 90k of output is the median of **a single
repetition**: the other two were segmented and their tokens discarded (`n = 1/3`). Time
and diff support the reading across all three repetitions; the token number supports it in
one. `gemini-3.1-pro` is the opposite on both time and volume. Volume is not quality — §5
puts the quality reading next to these numbers.

**Tokens exist in both harnesses, but the `cursor-agent` ones need checking before
aggregation.** The `usage` on the `result` event covers only the last segment of a run: in
3 of the 15, the reported `outputTokens` could not have produced its own diff. They are
`claude-sonnet-5-thinking-high` r1 (1,166 tokens for 55,610 bytes, one eighth of the
possible minimum) and r2 (7,425 for 57,440, half of it), plus `gpt-5.6-terra-high` r2 (226
for 27 KB). The other 12 land at 22–35 tokens per line, coherent. **The two models with
the most turns are the two affected** — the longer the run, the more chance it was
resumed, and it is the resumption that truncates the accounting.
`metrics.json` records `tokens_plausible`, and `false` there means "segmented run", not
"the model produced little" — the worst case is precisely the 6113s outlier.

**The `opencode` routes are 2 to 4 times slower, and that is not the model.** Generation
medians land at 1713s, 2494s and 2675s, against 413s to 1146s on `cursor-agent`. Since the
harness is identical across the three `opencode` rows and they still vary from 1713s to
2675s, the difference is in the gateway, not the binary.

**Reliability separates the two populations more than speed does.** All five
`cursor-agent` routes needed **3 attempts for 3 repetitions**. Three of the four
`opencode` routes needed **4 for 3** — two gateway stalls and one content filter. It is a
cost that only surfaces because the discarded attempts were kept in `stalled-runs/`
instead of being deleted.

**Cost per approved solution is uncomputable in both populations:** `cursor-agent` reports
no price and `opencode` reports zero.

---

## 5. Judging

### How the scoring works

Only candidates that pass Tier 0 get here. Each is scored by **Opus 5** against the diff
that actually shipped, on **six independent criteria** from 1 to 5:

| Criterion | What it measures |
|---|---|
| `spec_adherence` | Every requirement met, nothing silently dropped |
| `behavioral_equivalence` | Same observable behaviour as the reference |
| `scope_discipline` | Change surface compared to the reference's |
| `correctness_beyond_tests` | Edge cases and error paths the suite does not cover |
| `codebase_fit` | Repository conventions — naming, idiom, structure |
| `maintainability` | Does a reviewer understand it in one pass? |

Three decisions make the score robust:

**The reference is worth 4, not 5.** It is the anchor — what an engineer delivered under a
deadline, not the optimum. The 5 is reserved for doing better than production, so the eval
is not capped at the status quo.

**Three independent judgments per candidate, consolidated by the median.** The judge is
non-deterministic, and the median discards the outlying pass. The **spread** across the
three is kept as a diagnostic: a low spread indicates a well-defined criterion. Across the
23 candidates the maximum spread was **1 point**, which indicates a stable rubric within a
single judging run — see the caveat about re-judging in the takeaways.

**Every deduction requires a `file:line` citation.** A deduction without evidence is
discarded, which keeps the score auditable line by line.

**Blinding.** Candidates reach the judge as `candidate-02`, `candidate-25` — the mapping to
the model lives in a file the judge never reads, and deanonymisation happens only when the
report is generated.

### Results — Tier 1

Median of the six criteria, maximum 30. `k` is how many repetitions were judged.

| Model | harness | k | total | per rep | spread | adher. | behav. | scope | corr. | fit | maint. |
|---|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|
| `cursor-grok-4.6-high` | cursor-agent | 3 | **19** | 21 / 19 / 19 | 1 | 3 | 3 | 4 | 3 | 3 | 3 |
| `claude-sonnet-5-thinking-high` | cursor-agent | 3 | 18 | 19 / 18 / 17 | 1 | 3 | 3 | 4 | 2 | 3 | 3 |
| `gpt-5.6-terra-high` | cursor-agent | 3 | 18 | 19 / 18 / 17 | 1 | 3 | 3 | 4 | 2 | 3 | 3 |
| `amazon-bedrock/anthropic.claude-sonnet-5` | opencode | 3 | 17 | 17 / 17 / 17 | 1 | 3 | 2 | 4 | 2 | 3 | 3 |
| `glm-5.2-high` | cursor-agent | 3 | 17 | 18 / 17 / 15 | 1 | 3 | 2 | 4 | 2 | 3 | 3 |
| `huawei-modelarts/glm-5.2` | opencode | 3 | 16 | 17 / 16 / 16 | 1 | 2 | 2 | 4 | 2 | 3 | 3 |
| `vtex-glm/huawei/glm-5.2` | opencode | 2 | 16 | 17 / 15 | 1 | 2.5 | 2 | 3.5 | 2 | 3 | 3 |
| `gemini-3.1-pro` | cursor-agent | 3 | 13 | 15 / 13 / 12 | 1 | 2 | 2 | 3 | 2 | 2 | 2 |
| `amazon-bedrock/openai.gpt-5.6-terra` | opencode | 0 | — | — | — | — | — | — | — | — | — |

### Results — Tier 0

**None of the 24 measured runs broke the pre-existing suite, with one exception**: the
`vtex-glm` `r2` left 21 of its own tests failing. No candidate, on any route, matched the
reference tests' contract.

| Model | at the gate | pass@k | pass^k | ref-tests | not measured | attempts |
|---|---|---|---|---|---|---|
| `cursor-grok-4.6-high` | 3/3 | yes | yes | 0/3 | — | 3 |
| `claude-sonnet-5-thinking-high` | 3/3 | yes | yes | 0/3 | — | 3 |
| `gpt-5.6-terra-high` | 3/3 | yes | yes | 0/3 | — | 3 |
| `glm-5.2-high` | 3/3 | yes | yes | 0/3 | — | 3 |
| `gemini-3.1-pro` | 3/3 | yes | yes | 0/3 | — | 3 |
| `amazon-bedrock/anthropic.claude-sonnet-5` | 3/3 | yes | yes | 0/3 | — | **4 for 3** |
| `huawei-modelarts/glm-5.2` | 3/3 | yes | yes | 0/3 | — | **4 for 3** |
| `vtex-glm/huawei/glm-5.2` | 2/3 | yes | **no** | 0/3 | — | **4 for 3** |
| `amazon-bedrock/openai.gpt-5.6-terra` | 0/0 | — | — | — | **3/3** | 3 |

Discarded attempts, in `stalled-runs/`:

| Route | repetition | reason | spent |
|---|---|---|---|
| `amazon-bedrock/anthropic.claude-sonnet-5` | r1 | `content-filter` at step 71 | 541s |
| `huawei-modelarts/glm-5.2` | r2 | `stalled` | 4381s, 110 steps |
| `vtex-glm/huawei/glm-5.2` | r1 | `stalled` during the reading phase | 2254s, 25 steps |

### Takeaways

**`cursor-grok-4.6-high` leads, and is the only one to score 3 on
`correctness_beyond_tests`.** A median of 19 with 21/19/19, the tightest dispersion in the
table, delivered in 864s — less than half the time of the runner-up on quality.

**`gpt-5.6-terra-high` is the best value.** It ties Sonnet 5 at 18 points using **413s
against 1136s** — nearly three times faster — and the lowest prompt consumption of the
five (144k tokens).

**The cleanest comparison in the eval is between the two `glm-5.2` routes.** Same harness,
same preamble, same worktree, same model: only the gateway changes. The result is
**identical quality and different reliability** — a median of 16 on both, against 3/3 at
the gate via Huawei and 2/3 via vtex-glm, the latter having also spent an extra attempt on
a stall. When the score is the same and the rate is not, the decision is about the route,
not the model.

**One-point differences do not survive between judging runs.** Re-judging exactly the same
diffs with the same rubric moved 4 of the 6 previous medians by 1 point — `cursor-grok`
fell from 20 to 19, `gemini` from 14 to 13, `glm-5.2-high` rose from 16 to 17 and the
Huawei route fell from 17 to 16. That inverted the last pair. The 1-point spread *within* a
judging run describes the stability of the three passes, not the stability between runs;
the safe reading is that **models separated by 1 point are tied**, and only differences of
2 or more order them.

**`scope_discipline` is where everyone does well** (3 or 4 across the whole table): no
model went refactoring beyond what was asked. It is the most uniform criterion and a good
signal about the quality of the specs.

**`correctness_beyond_tests` is where almost everyone does badly** — a 2 in eight of the
nine rows. It is the criterion that measures edge cases and error paths the suite does not
cover, and that is exactly where the gate does not help: passing the suite says nothing
about what the suite does not test. With 0/3 on the reference contract across every route,
this is the eval's substantive finding — the models deliver something that runs and breaks
nothing, and none reaches the behaviour that shipped.

**Sonnet 5 across the two harnesses is not comparable, and the difference is small
anyway.** 18 via `cursor-agent` against 17 via `opencode`/Bedrock — inside the 1-point
margin above. Between those two rows the harness, the gateway and the deployment all
change at once, so even a larger difference could not be attributed. What can be observed
is volume: 117k output tokens via Bedrock against 90k via Cursor, for equivalent scores.

**`vtex-glm/r2` is the only real defect in the whole eval, and it is worth understanding
why.** The 21 tests it broke are in the three files the reference itself had to change —
precisely the ones the gate does **not** restore by force, so as not to fail a candidate
for legitimately updating a mock. In other words: the candidate wrote implementation and
tests, and failed its own tests. It is not gate strictness, it is incoherence in the run.
