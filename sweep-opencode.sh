#!/usr/bin/env bash
# Runs every model in models-opencode.txt k times against one spec, through
# `opencode`. Sibling of sweep.sh; that file is untouched.
#
#   usage: ./sweep-opencode.sh [spec-name] [--reps N]    (or: export SPEC=pr-311)
#
# Resumable and non-fatal on a single failure, same as sweep.sh. Serial, also for
# the same reason: per-run wall clock is a reported metric, and concurrent runs
# contend for CPU, disk and network until it stops comparing anything.
set -uo pipefail

# KEEP THE MACHINE AWAKE FOR THE WHOLE SWEEP.
# A sweep runs for hours — the pr-1644 one took nine — and a laptop will suspend in the
# middle of it. That is not a harmless pause: on pr-1644 seven runs were recorded as
# `stalled` because the watchdog measures wall clock, and one of them spent 8210 of its
# 8364 seconds suspended. Nothing could progress, the silence limit elapsed anyway, and
# the whole opencode population had to be discarded. The watchdog now discounts clock
# jumps, but not sleeping in the first place is what actually saves the sweep: an agent
# mid-request when the machine suspends can also come back to an expired credential,
# which is how three more runs died on `Bearer Token has expired`.
#
# Re-exec under caffeinate rather than telling the reader to remember it. -i holds off
# idle sleep, -s holds off system sleep on AC. Closing the lid still suspends; if that
# is the plan, run the sweep on a machine that stays open.
if [ -z "${SWEEP_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  export SWEEP_CAFFEINATED=1
  exec caffeinate -is "$0" "$@"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="${EVAL_ROOT:-$HERE}"
REPS="${REPS:-3}"
SPEC_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reps) REPS="$2"; shift 2 ;;
    --reps=*) REPS="${1#*=}"; shift ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) SPEC_ARG="$1"; shift ;;
  esac
done
SPEC_NAME="${SPEC_ARG:-${SPEC:-}}"
[ -n "$SPEC_NAME" ] || { echo "usage: $(basename "$0") <spec-name>   (or: export SPEC=pr-311)" >&2; exit 1; }

[ -d "$EVAL_ROOT/specs/$SPEC_NAME" ] || {
  echo "no spec at $EVAL_ROOT/specs/$SPEC_NAME — run extract-spec.sh first" >&2; exit 1; }

if [ ! -x "$EVAL_ROOT/specs/$SPEC_NAME/verify.sh" ]; then
  echo "warning: no verify.sh for $SPEC_NAME — runs will complete but cannot be" >&2
  echo "         scored, and blind.sh will discard all of them (§1)." >&2
  printf '         continue anyway? [y/N] ' >&2
  read -r ans; [ "$ans" = y ] || exit 1
fi

# bash 3.2 on macOS has no mapfile.
MODELS=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  MODELS+=("$line")
done < <(grep -v '^[[:space:]]*#' "$EVAL_ROOT/models-opencode.txt" | grep -v '^[[:space:]]*$')
[ "${#MODELS[@]}" -gt 0 ] || { echo "no models in models-opencode.txt" >&2; exit 1; }

TOTAL=$(( ${#MODELS[@]} * REPS ))
printf '%s via opencode: %s models x %s reps = %s runs\n\n' \
  "$SPEC_NAME" "${#MODELS[@]}" "$REPS" "$TOTAL"

N=0; OK=0; FAIL=0; SKIP=0
SWEEP_START=$(date +%s)

for MODEL in "${MODELS[@]}"; do
  MODEL_DIR="opencode__$(printf '%s' "$MODEL" | tr '/' '_')"
  for ((REP = 0; REP < REPS; REP++)); do
    N=$((N + 1))
    OUT="$EVAL_ROOT/runs/$SPEC_NAME/$MODEL_DIR/r$REP"

    if [ -f "$OUT/metrics.json" ]; then
      printf '[%2d/%2d] %-38s r%s  skip (done)\n' "$N" "$TOTAL" "$MODEL" "$REP"
      SKIP=$((SKIP + 1)); continue
    fi

    printf '[%2d/%2d] %-38s r%s  ' "$N" "$TOTAL" "$MODEL" "$REP"
    mkdir -p "$OUT"
    LOG="$OUT/sweep.log"
    START=$(date +%s)
    if EVAL_ROOT="$EVAL_ROOT" \
       "$HERE/run-one-opencode.sh" "$SPEC_NAME" "$MODEL" "$REP" > "$LOG" 2>&1; then
      printf 'ok    %ss\n' "$(( $(date +%s) - START ))"
      OK=$((OK + 1))
    else
      printf 'FAIL  %ss  (see %s)\n' "$(( $(date +%s) - START ))" "$LOG"
      FAIL=$((FAIL + 1))
    fi
  done
done

printf '\n%s runs: %s ok, %s failed, %s skipped, %ss total\n' \
  "$TOTAL" "$OK" "$FAIL" "$SKIP" "$(( $(date +%s) - SWEEP_START ))"
printf 'these runs carry harness="opencode" in metrics.json — keep them separate\n'
printf 'from the cursor-agent population when reporting (§10).\n'
printf 'next: blind.sh %s, then judge.py %s\n' "$SPEC_NAME" "$SPEC_NAME"
