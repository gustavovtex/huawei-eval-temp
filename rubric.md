# Rubric — DRAFT, tune before trusting

Six criteria, scored 1–5 **independently**. The reference diff is the anchor.

> **This file is a starting point, not a finished rubric.** §8 exists because a
> rubric written blind is usually wrong: run the reference against itself first
> (it should land on 4 across the board), then hand-grade ~10 real artifacts and
> compare. Rewrite any criterion where you and the judge disagree, or where the
> three passes disagree with each other. A ranking from an unvalidated rubric is
> a number with no meaning attached.

## Two rules that override everything below

1. **The reference is a 4, not a 5.** It is what one engineer shipped under one
   deadline — good, not optimal. A candidate that is genuinely better than the
   reference on a criterion scores 5. Do not treat the reference as a ceiling.
2. **Deduct for different *behavior*, never for different *approach*.** A
   candidate that reaches the same observable outcome by a different route is
   correct. Different file layout, different helper decomposition, different
   naming — none of these are deductions in themselves.

Every deduction requires a `file:line` citation and must say which diff it
points at. A deduction without a citation is discarded.

---

## spec_adherence

Every requirement in `SPEC.md` met; nothing silently dropped or reinterpreted.
The reference shows which requirements were load-bearing in practice.

- **5** — every requirement met, including ones the reference handled implicitly
- **4** — every stated requirement met (reference level)
- **3** — one minor requirement missed or reinterpreted without saying so
- **2** — a central requirement missed, or several minor ones
- **1** — solves a different problem than the one specified

## behavioral_equivalence

Same observable behavior as the reference: same outputs, same error paths, same
edge-case handling. Implementation is free; behavior is not.

- **5** — matches the reference and handles a case the reference gets wrong
- **4** — behaviorally indistinguishable from the reference (reference level)
- **3** — diverges on one edge case unlikely to be hit
- **2** — diverges on a case that will be hit in normal use
- **1** — core behavior differs from the reference

## scope_discipline

Surface area measured against the reference: files touched, abstractions
introduced, defensive handling added. The reference calibrates how much change
the task warranted.

- **5** — achieves the outcome with less incidental change than the reference
- **4** — comparable surface area to the reference (reference level)
- **3** — one unrequested abstraction, helper, or refactor
- **2** — several, or an unrequested restructuring of surrounding code
- **1** — the task is buried inside a rewrite nobody asked for

## correctness_beyond_tests

Edge cases the suite misses; error paths; concurrency; boundary conditions. The
reference's handling shows which ones mattered enough to survive production.
Tier 0 already reports whether the tests pass — do not re-score that here.

- **5** — handles a real failure mode the reference leaves open
- **4** — same error and boundary handling as the reference (reference level)
- **3** — one plausible edge case unhandled
- **2** — an error path that will be hit is unhandled or handled wrongly
- **1** — correct only on the happy path

## codebase_fit

The reference *is* the convention, by definition — naming, comment density,
idiom, structure, error-handling style.

- **5** — indistinguishable from surrounding code, including comment density
- **4** — matches the reference's conventions (reference level)
- **3** — one visible foreign idiom (naming style, comment verbosity, layout)
- **2** — reads as written by someone who didn't look at the codebase
- **1** — imports a different language's or framework's idioms wholesale

## maintainability

Would a reviewer understand it in one pass?

- **5** — clearer than the reference; intent obvious without commentary
- **4** — as readable as the reference (reference level)
- **3** — one section requires re-reading
- **2** — reviewer would need to ask the author what it does
- **1** — effectively unreviewable
