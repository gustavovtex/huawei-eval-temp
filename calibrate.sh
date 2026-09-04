#!/usr/bin/env bash
# §8 step 0 — score the reference as if it were a candidate.
#
#   usage: ./calibrate.sh [spec-name]          (or: export SPEC=pr-1234)
#
# One judge call, zero generation cost, and the highest-signal check in the whole
# design. The reference should land on roughly 4 across every criterion, because
# that is where rubric.md anchors it. Two ways it can come back wrong:
#
#   below 4  the rubric contradicts the code that actually shipped and survived
#            production — the rubric is wrong, not the reference
#   5 everywhere  the rubric has no headroom above the reference, or the spec
#            leaked implementation detail and the judge is rewarding a match
#
# Either way, fix rubric.md and run this again BEFORE spending on a sweep. A
# ranking from an uncalibrated rubric is a number with no meaning attached.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="${EVAL_ROOT:-$HERE}"
SPEC_NAME="${1:-${SPEC:-}}"
[ -n "$SPEC_NAME" ] || { echo "usage: $(basename "$0") <spec-name>   (or: export SPEC=pr-1234)" >&2; exit 1; }

SPEC_DIR="$EVAL_ROOT/specs/$SPEC_NAME"
[ -f "$SPEC_DIR/reference-impl.patch" ] || {
  echo "no reference-impl.patch for $SPEC_NAME — run extract-spec.sh first" >&2; exit 1; }

# Note: blind.sh does `rm -rf anon/<spec>` when it runs, so this candidate is
# transient. That is fine — the verdict in judged/ persists. Re-run calibrate.sh
# after any rubric edit, not after every sweep.
REF="$EVAL_ROOT/anon/$SPEC_NAME/candidate-REF"
mkdir -p "$REF"
cp "$SPEC_DIR/reference-impl.patch" "$REF/diff.patch"

# The reference is by definition the code the reference tests were written
# against, so Tier 0 is a formality here — it is what "passing" is defined as.
cat > "$REF/verify.json" <<'JSON'
{
  "pass": true,
  "note": "reference implementation — Tier 0 passes by definition",
  "fail_to_pass": { "passed": true },
  "pass_to_pass": { "passed": true }
}
JSON

printf 'scoring the reference against itself — expect ~4 on every criterion\n\n'
EVAL_ROOT="$EVAL_ROOT" "$HERE/judge.py" "$SPEC_NAME" --candidate candidate-REF "${@:2}"

MEDIAN="$EVAL_ROOT/judged/$SPEC_NAME/candidate-REF.median.json"
[ -f "$MEDIAN" ] || { echo "no verdict produced" >&2; exit 1; }

printf '\nper-criterion medians:\n'
python3 - "$MEDIAN" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
off = []
for name, c in m["criteria"].items():
    mark = ""
    if c["median"] < 3.5:
        mark = "  <-- rubric marks down production code"; off.append(name)
    elif c["median"] > 4.5:
        mark = "  <-- no headroom above the reference"; off.append(name)
    print(f"  {name:<26} {c['median']:>4}   scores={c['scores']} spread={c['spread']}{mark}")
print(f"\n  total={m['total_median']}  (expected around {4 * len(m['criteria'])})")
if off:
    print(f"\n  {len(off)} criteria are miscalibrated: {', '.join(off)}")
    print("  fix rubric.md and re-run calibrate.sh before sweeping.")
    sys.exit(1)
print("\n  calibration looks sane — safe to sweep.")
PY
