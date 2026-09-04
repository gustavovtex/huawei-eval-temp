# spec-eval

Scores N coding-agent models against the same spec, anchored on the diff that actually
shipped. Take a merged PR, roll the repo back to the commit before it, hand the PR's spec
to each model, and compare what each produces against production code — first
mechanically, then with a rubric.

## Start here

| If you want to… | Read |
|---|---|
| understand what this measures and why | [`STRATEGY-SUMMARY.md`](STRATEGY-SUMMARY.md) — §1 for the question and method, §3 for the design decisions |
| see the actual results | `STRATEGY-SUMMARY.md` §4 (cost, time, tokens) and §5 (rubric scores) |
| run it | the pipeline below |
| check on a sweep that is running | `./status.sh <spec>` |
| know how a criterion is scored | [`rubric.md`](rubric.md) |

The full rationale — every decision with its alternatives — lives in
[`spec-eval-design.md`](spec-eval-design.md). `STRATEGY-SUMMARY.md` is the short version
of it; the design doc is where each choice is argued against the alternatives it beat.

## The pipeline

Once per spec:

| Step | Command | Produces |
|---|---|---|
| 1. PR → spec | `./extract-spec.sh` | `specs/<spec>/` with `SPEC.md`, `base-repo/`, reference patches |
| 2. Establish the gate | `./derive-tests.sh <spec>` | `verify.sh`, plus `tests.json` proving the spec can measure anything |
| 3. Calibrate the rubric | `./calibrate.sh <spec>` | scores the reference as if it were a candidate — it should land on 4 |

Per sweep:

| Step | Command | Produces |
|---|---|---|
| 4. Generate | `./sweep.sh <spec>` (or `./sweep-opencode.sh <spec>`) | `runs/<spec>/<model>/r<n>/` — diff, transcript, metrics, gate verdict |
| 5. Blind | `./blind.sh <spec>` | `anon/<spec>/candidate-XX/` and a mapping the judge never reads |
| 6. Judge | `./judge.py <spec>` | `judged/<spec>/*.median.json` |
| 7. Report | `./report.py <spec> --md` | the three tables — deanonymisation happens here and only here |

Which models run comes from `models.txt` (via `cursor-agent`) and `models-opencode.txt`
(via `opencode`). Those two are **separate populations** and the report keeps them apart:
a difference between them changes the harness, the gateway and the deployment at once.

To see what a sweep is doing, at any point:

- `./status.sh <spec>` — per-run state: passed, failed, stalled, not measured, still
  running. Reads artefacts only, so it is safe to run at any time, including mid-sweep.

## Layout

Tracked in git: the scripts, `rubric.md`, and the two model lists. Everything else is
data, and is deliberately untracked:

```
specs/         one directory per spec: SPEC.md, base-repo/, the gate, reference patches
runs/          one directory per (spec, model, repetition)
anon/          blinded candidates + the model↔candidate mapping
judged/        rubric verdicts, keyed by candidate label
stalled-runs/  attempts that were discarded and regenerated, kept for the record
```

`stalled-runs/` is not a junk drawer. The report reads it and counts those attempts as
reliability cost of a route, which is what stops regenerating a failure from erasing it.

## Before a long sweep

A sweep runs for hours, and the failures that cost the most have nothing to do with the
models:

- **Plug the machine in, lid open.** The sweeps re-exec themselves under `caffeinate`, but
  a closed lid suspends anyway, and a battery will not last a full sweep of generation.
- **Refresh credentials first.** Anything with a short-lived token — a Bedrock API key in
  `~/.local/share/opencode/auth.json`, for instance — expires on the wall clock, mid-sweep,
  and nothing in the harness can renew it.
- **A sweep resumes.** It skips any run that already has `metrics.json`, so re-running the
  same command continues where it stopped. Note that `metrics.json` is written *before* the
  gate, so a run interrupted during the test suite resumes as "done" with a missing
  verdict; delete that run's directory to have it generated again.

## Reading the results

Two caveats matter more than any single number:

**Models separated by 1 point are tied.** Re-judging the same diffs with the same rubric
moved 4 of 6 medians by a point. The spread reported per candidate describes agreement
among three passes, not stability between judging runs.

**Not every failure is the model's.** The report separates a real defect from a run that
was interrupted (stall, content filter, gate timeout) from one that was never measured at
all (an IAM denial, an expired credential). Runs in the last category are excluded from the
denominator rather than counted as losses.
