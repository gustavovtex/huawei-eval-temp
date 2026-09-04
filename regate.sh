#!/usr/bin/env bash
# Re-runs Tier 0 against runs that were already generated, without re-invoking any
# model. Use after changing verify.sh: the gate verdict lives in the run directory,
# but it was produced inside a worktree that run-one.sh deleted, so it cannot be
# refreshed in place.
#
#   usage: ./regate.sh [spec-name] [--only <model-dir>] [--force]
#          (or: export SPEC=pr-311)
#
# The saved diff.patch plus base.sha is enough to rebuild each candidate's tree
# exactly, so this costs `install + suite` per run instead of the full
# `agent + install + suite` a re-sweep would cost. On pr-311 that is minutes per run
# against roughly ten, and it invokes no model at all.
#
# Serial on purpose: the suite is the whole cost here and concurrent runs would
# contend for CPU and disk. Non-fatal per run — one failure does not stop the rest.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="${EVAL_ROOT:-$HERE}"

ONLY=""; FORCE=0; SPEC_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --force) FORCE=1; shift ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) SPEC_ARG="$1"; shift ;;
  esac
done
SPEC_NAME="${SPEC_ARG:-${SPEC:-}}"
[ -n "$SPEC_NAME" ] || { echo "usage: $(basename "$0") <spec-name>   (or: export SPEC=pr-311)" >&2; exit 1; }

SPEC_DIR="$EVAL_ROOT/specs/$SPEC_NAME"
RUNS="$EVAL_ROOT/runs/$SPEC_NAME"
[ -d "$RUNS" ] || { echo "no runs for $SPEC_NAME" >&2; exit 1; }
[ -f "$SPEC_DIR/config.env" ] || { echo "no spec at $SPEC_DIR" >&2; exit 1; }
# shellcheck source=/dev/null
. "$SPEC_DIR/config.env"
export REPO BASE_REPO BASE TIP SPEC_PATH TEST_PATHS

[ -x "$SPEC_DIR/verify.sh" ] || { echo "no verify.sh — run derive-tests.sh first" >&2; exit 1; }

# THE GUARD THAT MATTERS. Re-gating with a stale verify.sh reproduces the same wrong
# verdicts and burns the whole run budget doing it — which is exactly the situation
# this script exists to clean up. Refuse unless derive-tests.sh has regenerated it.
if ! grep -q 'base-tests.tar' "$SPEC_DIR/verify.sh"; then
  echo "verify.sh predates the two-run gate — re-gating would reproduce the old" >&2
  echo "  verdicts. Run derive-tests.sh first, then this." >&2
  exit 1
fi
for t in base-tests.tar reference-tests.tar; do
  [ -s "$SPEC_DIR/$t" ] || { echo "missing $SPEC_DIR/$t — re-run extract-spec.sh" >&2; exit 1; }
done

TOTAL=0; DONE=0; SKIP=0; FAIL=0; PASSED=0
START_ALL=$(date +%s)

# A Ctrl-C in the middle of the loop left the current worktree registered, and the
# next re-gate of that same rep then failed on `worktree add` for a path whose
# directory no longer existed. WT is tracked outside the loop so the handler can reach
# whichever one is live.
WT=""
_cleanup() {
  [ -n "$WT" ] && git -C "$BASE_REPO" worktree remove --force "$WT" >/dev/null 2>&1
  return 0
}
trap _cleanup EXIT
trap '_cleanup; trap - EXIT; exit 130' INT
trap '_cleanup; trap - EXIT; exit 143' TERM

for RUN in "$RUNS"/*/r*; do
  [ -d "$RUN" ] || continue
  REP="$(basename "$RUN")"
  MODEL_DIR="$(basename "$(dirname "$RUN")")"
  [ -z "$ONLY" ] || [ "$MODEL_DIR" = "$ONLY" ] || continue
  TOTAL=$((TOTAL + 1))
  LABEL="$MODEL_DIR $REP"

  if [ ! -f "$RUN/diff.patch" ]; then
    printf '%-46s incompleto, sem diff.patch — pulado\n' "$LABEL"
    SKIP=$((SKIP + 1)); continue
  fi

  # Already carries the two-run verdict: nothing to redo unless forced.
  if [ "$FORCE" -eq 0 ] && [ -f "$RUN/verify.json" ] \
     && grep -qE '"regression"|"regated"' "$RUN/verify.json"; then
    printf '%-46s ja re-avaliado — pulado\n' "$LABEL"
    SKIP=$((SKIP + 1)); continue
  fi

  # Keep the superseded verdict once, so the before/after is auditable. Only the
  # first time — a second re-gate must not overwrite the original with a re-gate.
  [ -f "$RUN/verify.json" ] && [ ! -f "$RUN/verify.json.pre-regate" ] \
    && cp "$RUN/verify.json" "$RUN/verify.json.pre-regate"

  # An empty diff is decided without touching the suite, exactly as run-one.sh does.
  if [ ! -s "$RUN/diff.patch" ]; then
    printf '{\n  "pass": false,\n  "regated": true,\n  "reason": "empty diff — candidate made no changes"\n}\n' \
      > "$RUN/verify.json"
    printf '%-46s diff vazio -> pass:false\n' "$LABEL"
    DONE=$((DONE + 1)); continue
  fi

  WT="/tmp/eval-regate/$SPEC_NAME/$MODEL_DIR/$REP"
  rm -rf "$WT"; mkdir -p "$(dirname "$WT")"
  # Clears registrations left by an earlier interrupted re-gate or run; only ones whose
  # directory is already gone.
  git -C "$BASE_REPO" worktree prune
  git -C "$BASE_REPO" worktree add --detach "$WT" "$BASE" >/dev/null 2>&1 || {
    printf '%-46s falhou ao criar worktree\n' "$LABEL"; FAIL=$((FAIL + 1)); continue; }

  if ! git -C "$WT" apply --binary "$RUN/diff.patch" 2>"$RUN/regate-apply.err"; then
    printf '%-46s diff.patch nao aplica (ver regate-apply.err)\n' "$LABEL"
    git -C "$BASE_REPO" worktree remove --force "$WT" >/dev/null 2>&1; WT=""
    FAIL=$((FAIL + 1)); continue
  fi
  rm -f "$RUN/regate-apply.err"

  printf '%-46s ' "$LABEL"
  T0=$(date +%s)
  ( cd "$WT" && SPEC_DIR="$SPEC_DIR" OUT="$RUN" "$SPEC_DIR/verify.sh" ) > "$RUN/verify.json.tmp" 2>>"$RUN/regate.log"
  RC=$?
  ELAPSED=$(( $(date +%s) - T0 ))

  # Only replace the verdict if verify.sh actually produced JSON. A crashed gate must
  # not leave an empty verify.json behind, which blind.sh would read as "no pass".
  if [ -s "$RUN/verify.json.tmp" ]; then
    mv "$RUN/verify.json.tmp" "$RUN/verify.json"
  else
    rm -f "$RUN/verify.json.tmp"
    printf 'gate nao produziu JSON (ver regate.log)\n'
    git -C "$BASE_REPO" worktree remove --force "$WT" >/dev/null 2>&1; WT=""
    FAIL=$((FAIL + 1)); continue
  fi

  # verify_wall_clock_s is now this re-gate's, not the original run's, so record that
  # the field changed provenance. generate_wall_clock_s and the token fields are left
  # untouched — they describe the agent, which did not run again.
  python3 - "$RUN/metrics.json" "$ELAPSED" <<'PY' 2>/dev/null || true
import json, sys, datetime
p, el = sys.argv[1], int(sys.argv[2])
try:
    m = json.load(open(p))
except Exception:
    raise SystemExit
m["verify_wall_clock_s"] = el
m["regated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(m, open(p, "w"), indent=2)
PY

  VERDICT="$(python3 -c "import json;d=json.load(open('$RUN/verify.json'));print('pass' if d.get('pass') else 'FAIL', '| ref-tests:', 'ok' if (d.get('reference_tests') or {}).get('passed') else 'no')" 2>/dev/null || echo '?')"
  printf '%-24s %ss\n' "$VERDICT" "$ELAPSED"
  DONE=$((DONE + 1))

  git -C "$BASE_REPO" worktree remove --force "$WT" >/dev/null 2>&1; WT=""
done

# Contado varrendo o estado final de TODOS os runs, nao os desta invocacao: num
# resume que pulou tudo, o contador local daria zero e a mensagem abaixo mandaria
# parar quando havia candidatos prontos.
PASSED=0
for V in "$RUNS"/*/r*/verify.json; do
  [ -f "$V" ] || continue
  grep -qE '"pass"[[:space:]]*:[[:space:]]*true' "$V" && PASSED=$((PASSED + 1))
done

printf '\n%s runs: %s re-avaliados, %s pulados, %s com erro, %ss total\n' \
  "$TOTAL" "$DONE" "$SKIP" "$FAIL" "$(( $(date +%s) - START_ALL ))"
printf '%s runs no portao, ao todo\n' "$PASSED"
if [ "$PASSED" -gt 0 ]; then
  printf 'next: blind.sh %s, then judge.py %s\n' "$SPEC_NAME" "$SPEC_NAME"
else
  printf 'nenhum run passou o portao — blind.sh nao teria o que julgar.\n'
  printf 'veja verify-regression.log num run para saber o que a suite reclamou.\n'
fi
