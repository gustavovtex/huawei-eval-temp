# Multi-model spec evaluation — design

Comparing N models on the same agentic coding spec, scored by a deterministic
gate plus an LLM judge, anchored on the change that actually shipped.

---

## 1. The governing principle: gate before you judge

An LLM judge is unreliable exactly where code is easiest to check
mechanically — does it compile, do the tests pass. Split scoring into two
tiers and never let the judge adjudicate what a compiler can:

| Tier | What it answers | Mechanism | Cost |
|---|---|---|---|
| **0 — Gate** | Does it build? Tests pass? Typecheck/lint clean? | `verify.sh` in the repo | Free, fast, unarguable |
| **1 — Judge** | Among solutions that *work*, which is better engineering? | Opus 5 + rubric, anchored on the reference diff | Expensive |

A run that fails Tier 0 scores zero and never reaches the judge. This cuts
judge spend roughly in proportion to your failure rate, and removes the
failure mode where a judge confidently praises code that doesn't run.

The corollary: **invest in `verify.sh` first.** Every check you can move from
Tier 1 to Tier 0 makes the whole eval cheaper and more trustworthy.

You don't have to write those tests — the repository already contains two versions
of them. Harvest both, and run the suite **twice**, with different sets:

| Run | Test files used | Role |
|---|---|---|
| **1 — regression** | the suite as it stood at `base.sha` | **The gate.** Did the candidate break what already worked? |
| **2 — contract** | the suite as it shipped at the reference | **A signal**, reported to Tier 1. Did it match the reference's contract? |

**Only run 1 gates.** This is the part that looks wrong until you hit it: the
obvious design is to require the shipped tests to pass, and that is exactly what
cannot be required. Reference tests are usually **white-box** — they import internal
symbols by name. On the first spec here, 34 of the 35 symbols the tests imported
either existed at the base or were named in the spec; one did not. Two models
implemented the feature and both failed the gate on `has no exported member
'SURFACES'` — a constant the spec describes conceptually 47 times and never names.

Requiring run 2 therefore penalises the one thing §6 says must never be penalised:
the same behaviour reached under a different internal name. Run 2 still carries real
signal, so it goes to the judge, which can weigh it against the reference diff and
tell a naming difference from a behavioural one. That call needs a reader; a
compiler cannot make it.

**Restore each set by force before its run** — that is what stops a candidate from
weakening or deleting tests to pass, and it is why the two runs are ordered: run 2's
files overwrite run 1's.

**With one exception, and it is load-bearing: run 1 does not restore the test files
the reference itself modified.** Restoring them unconditionally makes run 1
unpassable for any candidate that legitimately updates a mock. On the first spec, the
implementation adds a call to `lmClient.listStorefrontRoles()`; the base version of
`users.test.ts` mocks `lmClient` without that method, so the base test throws
`TypeError` against *any* correct implementation — the reference included. All three
runs of one model failed the gate on it while passing 1222 of 1233 tests.

The reference's own file list is what makes this safe to concede. It changed those
same files (17 mock additions), which proves the update is required rather than
cheating. Files the reference did *not* touch are still restored by force, so a
candidate cannot weaken an unrelated test to pass; files it did touch are left as the
candidate wrote them, because the feature cannot exist without changing them.
`derive-tests.sh` derives the list from `reference-tests.patch` into
`reference-touched-tests.txt`.

Validate the rule by running the reference through its own gate: it must pass run 1.
If it does not, the exception is drawn in the wrong place, and no candidate can pass
either.

Four rules make this work, and the last three exist because the first sweep
violated all of them at once:

- **The candidate never sees the tests.** It runs in a worktree at `base.sha`,
  where they don't exist yet; `verify.sh` brings them in afterward. A model that
  can read the tests optimizes against them, and you end up measuring overfitting.
- **`verify.sh` restores each set from an archive, not from git.** The candidate's
  repository is cut at `base.sha` (§2) and cannot reach the reference commit, so
  there is no ref to check out — `extract-spec.sh` ships `base-tests.tar` and
  `reference-tests.tar` instead.
- **Assert the restore landed, and never swallow its failure.** Check every path in
  the archive exists afterward; abort the gate if one doesn't. The original used
  `git checkout … 2>/dev/null || true` with an unquoted pathspec, so a restore that
  silently did nothing left the suite running *without* the new tests — green by
  definition, and recorded as a pass.
- **An empty diff fails before the suite runs.** A candidate that changed nothing is
  not a candidate. Without this rule a no-op run reaches the gate, the suite passes
  because it is still the base suite, and a model that did no work outranks one that
  tried and missed.

---

## 2. Run isolation

One git worktree per `(spec, model, repetition)`, all branched from the same
frozen base commit — **and cut from a repository that cannot reach the answer**:

```
git init --bare specs/<spec>/base-repo
git -C specs/<spec>/base-repo fetch --no-tags <repo> <base-sha>:refs/heads/eval-base
git -C specs/<spec>/base-repo worktree add /tmp/eval/<spec>/<model>/r<k> <base-sha>
```

**Do not cut worktrees from the working clone.** They inherit every ref it has,
including the branch holding this PR's implementation and the merge commit itself,
and a candidate can simply read the solution out of `git log`. This is not a
theoretical risk — on the first sweep two of three runs found the feature branch,
concluded the work was already done, and returned an empty diff. One of them
checked the branch out and reported the reference implementation's own test run as
its result.

Fetching a single SHA into a fresh bare repo copies only what is reachable *from*
that commit, so nothing after the base exists. History up to the base survives, so
a model can still read `git log` for conventions. Assert it afterward:
`git -C base-repo cat-file -e <tip-sha>` must fail.

Requirements:

- **Frozen base, derived from the merge topology.** The input to a spec is a
  **merged PR number**, a repo, and the spec file's path inside it;
  `extract-spec.sh` derives the rest. This repo does **not** squash-merge, so a PR
  is a *range* of commits rather than one commit — the eval only ever needed
  `(base state, net change)`, and a range diff supplies both:

  ```sh
  TIP=$(gh pr view "$PR" --json mergeCommit --jq .mergeCommit.oid)
  N=$(gh pr view "$PR" --json commits --jq '.commits | length')

  # 2 parents → merge commit; 1 parent → rebase merge (commits replayed inline)
  case $(( $(git rev-list --parents -n 1 "$TIP" | wc -w) - 1 )) in
    2) BASE=$(git rev-parse "$TIP^1") ;;
    1) BASE=$(git rev-parse "$TIP~$N") ;;
  esac

  git show "$TIP:$SPEC_PATH" > SPEC.md    # the prompt, verbatim — see §6
  git diff "$BASE..$TIP" -- $TEST_PATHS > reference-tests.patch
  git diff "$BASE..$TIP" -- . \
    $(printf ":(exclude)%s " $SPEC_PATH $TEST_PATHS) > reference-impl.patch
  ```

  Strategy is detected per PR, so a repo that mixes merge-commit and rebase merges
  needs no configuration.

  **Cross-validate the range against the PR's own file list.** A wrong `BASE`
  produces a task that is already partly done, every model looks better than it
  is, and nothing downstream reveals it — the runs pass, the judge scores them,
  the report reads fine. The check is cheap and total:

  ```sh
  diff <(gh pr view "$PR" --json files --jq '.files[].path' | sort -u) \
       <(git diff --name-only "$BASE..$TIP" | sort -u)
  ```

  Any difference means the derived base is wrong — stop rather than proceeding.
  This is the single highest-value assertion in the extraction, because it is the
  only one that catches a base error at all.

  A moving base invalidates cross-model comparison; a base that isn't the
  reference's parent means the shipped change is either already in the tree or in
  conflict with itself.

  **The spec file is excluded from `reference-impl.patch`, not just copied out of
  it.** It ships inside the PR's own range, so a naive extraction leaves it
  in the implementation diff — and then the judge sees it twice (once as the
  prompt, once as reference "work"), and *scope discipline* is scored against a
  reference that touched a file the candidate was never asked to touch. Exclude
  `$SPEC_PATH` from the candidate's captured `diff.patch` too, for the same
  reason.

  `$SPEC_PATH` and `$TEST_PATHS` are the only repo-specific parts here. Get them
  right once and the rest is mechanical.

- **Establish the preconditions once per spec, not per run.** Run the suite three
  times at `base.sha` and record the outcomes in `tests.json`: clean (must pass —
  a red base means every candidate inherits failures it did not cause), with the
  reference tests restored (must **fail** — if the shipped tests already pass
  without the change, they do not test it and the spec measures nothing), and at
  the reference itself (must pass). All three holding is what makes the spec
  usable; any one of them wrong and the sweep should not run.
- **Clean tree at start.** Verify before each run; a dirty worktree silently
  contaminates the diff.
- **Cleanup after capture,** not before — you want the worktree intact while
  you extract artifacts.

Worktrees are cheap (~200–500ms setup) and they're the only reliable way to
run models concurrently against the same repo without collisions.

---

## 3. What to capture per run

The final diff is *not* enough. Capture all of:

| Artifact | Why |
|---|---|
| `diff.patch` | `git diff --cached <base-sha>` after `git add -A` — staged so untracked files land in it, and diffed against the **base sha explicitly, never against `HEAD`**. A candidate that checks out a branch, resets, or commits moves `HEAD`, and a bare `diff --cached` then reports nothing changed |
| `transcript.jsonl` | Full tool-call sequence. Reveals thrash, dead ends, wasted exploration that the diff hides |
| `metrics.json` | **Wall clock split by phase** — `generate_wall_clock_s` (the agent) and `verify_wall_clock_s` (install + suite) kept apart, because install time is infrastructure and folding it in makes a model look slow when the package manager was slow. Plus `duration_ms` / `duration_api_ms` from the agent's own result event (waiting on the model vs thrashing tools locally), turn count, and **termination reason** |
| `verify.json` | Tier 0 results — `pass` (the regression run alone), plus `regression` and `reference_tests` recorded separately with their exit codes. The second is a signal for the judge, not part of the verdict |

**Termination reason is load-bearing.** If one model hits your max-turn cap
and another finishes naturally, you're comparing a truncated run to a complete
one. Record it and treat cap-hits as a distinct outcome, not a failure.

**And one of those outcomes is a stall.** A run can stop producing output without
ending: on pr-311 an opencode run wrote 418 KB in four minutes, stopped at a
`step_finish` waiting on a gateway request that never returned and never timed out,
and then sat there — its shell eventually killed, the agent process outliving it by
more than two hours, idle, still holding a worktree registration. Nothing in the chain
had a timeout, so nothing could end it.

The guard is a **stall** detector rather than a timeout, because an absolute cap has to
be enormous to be safe — the slowest run that completed and scored took 6103 seconds —
and a cap that generous catches nothing. Silence is the unambiguous signal: both agents
stream events continuously while working, so no growth in `transcript.jsonl` for
`STALL_S` (default 1800) means the run is over whether or not the process knows it. The
agent tree is killed, `termination_reason` is set to `stalled`, and capture proceeds
anyway — a partial diff from a stalled run is data, and discarding it would hide the
failure mode.

Treat `stalled` the way you treat a cap-hit: a distinct outcome, neither a pass nor a
model's fault. It is a property of the run, and a model whose runs stall often is
telling you something about the route to it, not about its ability.

---

## 4. Repetitions — one run per model is noise

Agentic runs have high variance: same model, same spec, materially different
solutions. A single run per model measures luck.

Run **k = 3–5 repetitions** per `(spec, model)` and report the distribution.
Two numbers worth separating:

- **pass@k** — did *any* run pass the gate? (capability ceiling)
- **pass^k** — did *every* run pass? (reliability — usually the number you
  actually care about for production)

A model at 5/5 is a meaningfully different proposition from one at 2/5 with a
brilliant best run, and a mean hides that completely.

---

## 5. Blinding

Strip model identity before artifacts reach the judge. For code this is harder
than for prose and **cannot be done completely** — models have stylistic tells
(comment density, file layout, naming, verbosity). Do what you can and accept
the residual:

- Rewrite commit messages to a fixed string
- Strip `Co-Authored-By` / generated-with footers
- Remove any self-reference in comments or docs
- Present as `candidate-A7`, `candidate-K2`, … with the mapping in a file the
  judge never reads
- Randomize presentation order per judging call

**The reference diff is not blinded.** It is labeled as the reference and the
judge is told exactly what it is — that's the entire point of having it.
Blinding applies only to the candidates, so they can't be ranked by house style.

One consequence to keep in mind: the reference is human-written production code
with the repo's conventions all over it, so a candidate that happens to match
those conventions closely will read as more reference-like across every
criterion. That's signal on *codebase fit* and noise everywhere else — keep the
criteria scored separately so it can't bleed.

The imperfection of blinding is another argument for weighting Tier 0 heavily
— it's the part that can't be gamed by style.

---

## 6. The reference diff and rubric

### The reference diff is the answer key

Every spec carries a `reference-impl.patch`: the change as it actually shipped,
and what runs in production today. The judge sees it, labeled as the reference,
and scores each candidate against it.

Note the split — the reference commit's *tests* go to the gate
(`reference-tests.patch`, §1) and the judge never sees them. They'd be token
cost for no rubric value: Tier 0 already reports pass/fail, and *correctness
beyond tests* is by definition about what those tests missed.

This is a far stronger anchor than a prose rubric alone. "Matches the
surrounding conventions" is an opinion; "the reference does it this way" is a
fact. Three consequences:

- **`base.sha` is the reference commit's parent** — see §2.
- **The reference is never a candidate.** It gets no run directory and does not
  appear in the ranking. It's the key, not a contestant.
- **`SPEC.md` is copied out of the repo, not authored.** This codebase is
  spec-driven: the spec file is committed alongside the change and the shipped
  implementation was generated from it. So the eval reuses the real artifact
  verbatim — `git show "$SHA:$SPEC_PATH"` (§2) — and there is nothing to rewrite
  and no leakage to scrub. A spec that predates its own implementation cannot
  describe it.

  Two caveats on that claim:

  - **Squash merges destroy the evidence.** Because the branch collapses to one
    commit, the spec file always appears for the first time *in* the reference
    commit, whatever order it was actually written in. `git log --follow` can't
    confirm the spec came first. You're trusting the process, not the history.
  - **Specs iterated during implementation are a partial leak.** If the author
    refined the spec as they discovered things — normal in spec-driven work — the
    committed version has been retrofitted toward what got built. Cheap check:
    read the spec and ask whether any requirement is suspiciously shaped like a
    specific implementation. If yes, that clause leaked, and it's the one to
    loosen.

  For any future spec that *doesn't* ship as a committed file — derived from a
  ticket, a PR description, or reconstructed from the diff — none of the above
  holds. State intent only, then diff your spec text against
  `reference-impl.patch` and delete every noun that appears in both.

The reference is one valid solution, not the only one — it's what a particular
engineer shipped under a particular deadline, and production code carries
compromises that had nothing to do with quality. Two guards keep the eval from
collapsing into a similarity-to-reference score:

- **Anchor the reference at 4, not 5.** Leave headroom so a candidate that is
  genuinely better than what shipped can say so. A scale that tops out at
  "matches the reference" caps the eval at the status quo.
- **Deduct for different *behavior*, never for different *approach*.** A
  candidate that reaches the same observable outcome by another route is not
  wrong. Put this in the judge prompt explicitly — it is the default failure
  mode of reference-anchored grading, and it will not correct itself.

One risk worth naming: if the repository is public or otherwise likely to sit in
training data, a candidate may reproduce the reference from memory rather than
solve the problem. For an internal repo this is minor. For anything public,
prefer specs drawn from recent commits, and treat a suspiciously exact match as
a finding to investigate rather than a top score.

### Scoring

Absolute scoring (each artifact graded independently, 1–5 per criterion), not
pairwise. Absolute is O(n) instead of O(n²), has no position bias, and lets you
add a model later without re-running everything. Reserve pairwise for a
tiebreak between the top two, run in both orders.

Suggested criteria — adapt to your codebase, but keep each one
**independently gradeable** with concrete anchors:

| Criterion | Anchors on |
|---|---|
| **Spec adherence** | Every requirement met; nothing silently dropped or reinterpreted. The reference shows which requirements were load-bearing in practice. |
| **Behavioral equivalence** | Same observable behavior as the reference — same outputs, same error paths, same edge-case handling. Different implementation is fine here; different behavior is not. |
| **Scope discipline** | Surface area measured against the reference: files touched, abstractions introduced, defensive handling added. The reference calibrates how much change the task actually warranted. |
| **Correctness beyond tests** | Edge cases the suite misses; error paths; concurrency; boundary conditions. The reference's handling shows which ones mattered enough to survive production. |
| **Codebase fit** | The reference *is* the convention, by definition — naming, comment density, idiom, structure. |
| **Maintainability** | Would a reviewer understand it in one pass? |

Write **anchored levels**, not adjectives. "3 = meets the stated requirements
but adds one unrequested abstraction" beats "3 = adequate". Vague criteria
produce noisy judging, and noise is what kills eval usefulness.

**Require evidence.** Demand a `file:line` citation for every deduction, and
discard deductions that don't carry one. This single constraint eliminates most
hand-wavy judging. Citations can now point at either diff, so require the judge
to say which: a deduction citing the reference is making a claim about
divergence, and that's precisely the claim you want to be able to audit.

Give the judge: the spec, the reference diff, the candidate diff, the Tier 0
results, and the rubric. Give it the transcript only if you're grading process
as well as outcome — it's a large token cost for a signal most rubrics don't
use.

---

## 7. Judge mechanics

- **Model:** Opus 5, run through `cursor-agent` as `claude-opus-5-thinking-xhigh`
  — same binary and credential as generation, so the eval needs one tool and no
  SDK. If Opus 5 ever becomes a *contestant*, judge with Fable 5 instead; LLM
  judges show measurable self-preference.
- **Effort:** `xhigh`, baked into the model id. Judging is exactly the
  intelligence-sensitive work where effort pays.
- **Sampling:** 3 judge passes per artifact, take the **median** per criterion.
  Opus 5 rejects `temperature`/`top_p`/`top_k`, so repeated sampling is the only
  variance handle — and inter-pass spread is a useful diagnostic in itself. A
  criterion where the three passes disagree is a criterion that needs rewriting,
  so store the spread alongside the median, never just the aggregate.
- **Validate client-side and retry.** `--output-format json` is a transport
  format, not schema enforcement: going through the CLI gives up
  `output_config.format`, so the verdict must be validated on receipt (six
  criteria present, score an integer 1–5, every deduction carrying `diff`,
  `file`, `line`, `reason`) and re-requested with the validation errors when it
  doesn't conform.

**Blinding survives only if the judge's workspace is isolated.** This is the one
real hazard of judging through an agent rather than the API. `cursor-agent` has
file access, and pointed anywhere near the eval tree it can read
`anon/<spec>.mapping.json`, or infer identity from the model names in `runs/`
paths, and §5 is defeated with no visible symptom. Run each judging call in a
throwaway directory containing nothing but the five inputs under neutral
filenames, with `--mode ask --sandbox enabled`. Read-only is precisely the
capability that leaks here, so mode restriction alone is not the mitigation —
the empty workspace is.

**Two costs of this route, both accepted.** There is no `cache_control`, so the
stable prefix (rubric + `SPEC.md` + reference diff) is re-sent on every pass
instead of being pinned and re-read at a tenth of the price — with 3 passes × k
reps × N models that is the single largest line item in judge spend. And there
is no `fallbacks` or `stop_reason`, so a refusal arrives looking like a
malformed answer rather than a labelled outcome; the retry loop absorbs it, but
the report cannot distinguish the two. Both are the price of one tool and one
credential. If judge cost or refusal accounting later becomes the constraint,
this is the piece to move back onto the API.

---

## 8. Validate the judge before trusting it

Do this **before** the full sweep, not after:

0. **Score the reference as if it were a candidate.** One judge call, zero
   generation cost, and it should come back at roughly 4 across every criterion —
   the anchor you defined in §6. If the judge marks production code down, your
   rubric contradicts the reality it's supposed to be calibrated against, and
   nothing downstream of it means anything. This is the cheapest and highest-signal
   check available; run it first and re-run it after every rubric edit.
1. Hand-grade ~10 artifacts yourself against the rubric.
2. Run the judge on the same 10.
3. Measure agreement.

If the judge disagrees with you on a third of them, the rubric is the problem —
fix it and re-check. A ranking produced by an unvalidated judge is a number
with no meaning attached.

Also seed two or three **deliberately bad** artifacts (broken edge case,
gratuitous over-abstraction, ignores half the spec). If the judge doesn't catch
them, stop and fix the rubric.

---

## 9. Directory layout

```
spec-eval/
  rubric.md
  specs/
    001-add-rate-limiting/
      SPEC.md                 # copied verbatim from the reference commit
      base.sha                # mainline state before the PR landed (derived, §2)
      base-repo/              # bare, one ref at base.sha — candidates worktree from HERE
      config.env              # REPO, BASE_REPO, BASE, TIP, SPEC_PATH, TEST_PATHS
      provenance.json         # PR number, subject, resolved SHAs, spec origin
      reference-impl.patch    # shipped implementation — answer key for the judge
      reference-tests.patch   # shipped tests, as a diff — for review
      base-tests.tar          # suite before the PR — restored for run 1, the gate
      reference-tests.tar     # suite as shipped — restored for run 2, the signal
      reference-touched-tests.txt  # test files the reference changed — exempt in run 1
      tests.json              # frozen preconditions: clean / with-reference / tip
      verify.sh               # Tier 0 gate; exit 0 = pass
  runs/
    001-add-rate-limiting/
      claude-opus-5/
        r0/{diff.patch,transcript.jsonl,metrics.json,verify.json}
        r1/…
      claude-sonnet-5/…
  anon/
    001-add-rate-limiting/
      candidate-A7/      # blinded copy fed to the judge
      mapping.json       # judge never sees this
  judged/
    001-add-rate-limiting/
      candidate-A7.{0,1,2}.json
  report.md
```

Generation and judging write to different trees, so you can **re-judge with a
revised rubric without re-paying for generation.** Given how much rubric
iteration this kind of eval needs, that separation earns its keep immediately.

---

## 10. Controlling confounds

Hold constant across models: system prompt, tool set, max-turn cap, base
commit, spec text, **and the task preamble**.

The preamble is the last of those and the easiest to forget, because it did not
exist at first: `SPEC.md` alone is a design document, not an instruction. Handed
over bare, one run spent 3.6 seconds, made zero tool calls, and replied *"What would
you like me to do with it?"* — while its two siblings inferred the task and worked
for nine minutes. That is not model variance; it is an ambiguous prompt, and it
lands squarely in the wall-clock numbers §11 reports.

So the prompt is a fixed preamble plus the spec verbatim. The preamble states that
the task is to implement, and contradicts the spec's own header where it claims the
work already shipped — true of the document, false of the worktree. It says nothing
about files, structure, or approach. Byte-identical for every model and repetition,
and stored per run, since it is an input to the measurement.

The one that needs an explicit decision: **effort level.**

- **Same effort for all** answers "which model is better at fixed config" —
  cleaner comparison, but handicaps models whose recommended setting differs.
- **Each at its recommended effort** answers "which *setup* should I ship" —
  more decision-relevant, less clean as a model comparison.

Both are valid. Pick one, state it in the report, and don't mix them within a
sweep.

**Decided for this sweep: each model at its own `-high`, limitation declared.**
With the five contestants in `models.txt`, holding effort constant is not
achievable — only holding the *label* constant is. `-high` is GLM's floor and
mid-ladder for Grok, Sonnet, and Terra; `gemini-3.1-pro` exposes no effort
dimension at all. So this sweep answers **"which setup should I ship"**, and the
report must say so rather than presenting rubric totals as a clean model
comparison. If a later sweep needs the cleaner question, the way to get it is to
run 2–3 effort levels per model where they exist and report the curve — at
roughly double the generation cost.

---

## 11. Reporting

Per model, per spec:

- Tier 0: pass@k and pass^k
- Tier 1: median rubric total among passing runs, **plus the spread**
- Tokens, cost, wall clock, median turn count
- **Cost per passing solution** — frequently the number that actually decides
  it, and the one a raw quality ranking obscures

Show distributions, not just means. With k = 3–5, a box plot or the raw values
per run is more honest than any single aggregate.

**The harnesses do not report the same metrics, so say which is which.** This is a
property of the tools, not of the models, and left unlabelled it reads as missing
data:

| | cursor-agent | opencode |
|---|---|---|
| Wall clock, split by phase | ✅ | ✅ |
| Termination reason | ✅ | ✅ |
| Agent-side duration | ✅ `duration_ms` / `duration_api_ms` | ✅ from event timestamps |
| Effort / activity count | `turns` (tool calls) | `steps` (model round-trips) + `tool_calls` |
| **Tokens** | ⚠️ `usage` on the result event — but see below | ✅ input / output / reasoning / cache read+write |
| **Cost** | ❌ not exposed | ⚠️ field exists, reports zero |

**Test the reported token counts before aggregating them.** cursor-agent's `usage`
appears to cover only the final segment of a run: on the first sweep, 3 of 15 runs
reported an `outputTokens` that could not possibly have produced their own diff — one
claimed 226 tokens for a 27 KB diff. A diff needs roughly one token per four
characters at minimum, so that check is cheap and decisive. Runs that fail it were
segmented (retried, resumed, or stalled), which makes the field a useful **anomaly
detector** rather than a usage total — the worst offender was also the run that took
14× longer than its siblings.

**Cost per passing solution — the number named above as the one that usually decides —
is not computable on either harness.** cursor-agent reports no price, and opencode
reports zero. Don't leave the column blank: say which half is missing, and rank on
quality, wall clock and token volume instead.

Note also that `turns` and `steps` count different things and must never be put in
one column. A tool call is not a model round-trip; a single step can contain several
tool calls, and a step with none still costs a request.

---

## 12. Suggested build order

1. Pick one merged PR that ships a spec file. Run `extract-spec.sh <pr> <repo>
   <spec-path>` (§2) and derive `tests.json`. No spec authoring; it's a copy.
2. `verify.sh` for that spec: restore the reference tests, run both sets, exit
   non-zero if either fails.
3. Manual run of two models, artifacts captured by hand. Confirm the diff and
   metrics capture is actually usable.
4. Rubric + judge on those artifacts. Score the reference against itself first,
   then validate against your own grading.
5. Only then automate the sweep.

Building the runner first is the common mistake — you end up with a fast
pipeline producing scores you don't trust.
