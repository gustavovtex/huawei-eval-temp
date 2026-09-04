#!/usr/bin/env bash
# One run = one (spec, model, repetition). This is the unit the sweep loops over.
# Per §12, get this working by hand on two models before automating anything.
#
#   usage: ./run-one.sh <spec-name> <model> [rep]
#          STALL_S=1800  kill the agent after this long with no transcript growth
#          MAX_S=0       absolute cap on the generation call; 0 = none
#          GATE_MAX_S=3600 absolute cap on the Tier 0 gate; 0 = none
#          HEARTBEAT_S=300 how often the watchdog reports elapsed/silent time
set -euo pipefail

EVAL_ROOT="${EVAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SPEC_NAME="${1:?spec directory name, e.g. pr-1234}"
MODEL="${2:?model id — see models.txt}"
REP="${3:-0}"
MAX_TURNS="${MAX_TURNS:-200}"   # identical for every model — §10

# STALL_S / MAX_S / POLL_S live here; see the file for why silence and not a timeout.
# shellcheck source=/dev/null
. "$EVAL_ROOT/lib-watchdog.sh"

SPEC_DIR="$EVAL_ROOT/specs/$SPEC_NAME"

# REPO, BASE, TIP, SPEC_PATH and TEST_PATHS come from the extraction, not from
# the environment — sourcing them is what guarantees the diff exclusion here uses
# the same SPEC_PATH the reference diff was built with (§2), and that verify.sh
# restores tests from the same TIP the reference patches came from.
# shellcheck source=/dev/null
. "$SPEC_DIR/config.env"
export REPO BASE_REPO BASE TIP SPEC_PATH TEST_PATHS
OUT="$EVAL_ROOT/runs/$SPEC_NAME/$MODEL/r$REP"
WT="/tmp/eval/$SPEC_NAME/$MODEL/r$REP"
mkdir -p "$OUT"
rm -rf "$WT"; mkdir -p "$(dirname "$WT")"

[ -d "${BASE_REPO:-}" ] || {
  echo "config.env has no BASE_REPO — re-run extract-spec.sh (§2)" >&2; exit 1; }

# --- 1. isolated worktree at the frozen base ---------------------------------
# From base-repo, never from the working clone: the latter carries every ref in
# the project, so the candidate could read the reference implementation straight
# out of git history. base-repo holds exactly one ref, at BASE.
#
# Prune first, and after the rm -rf above. A run whose shell was SIGKILLed leaves the
# worktree registered while its directory is gone, and `worktree add` then refuses the
# path as already registered — every later attempt at this rep fails on a corpse from
# the first. Prune only drops registrations whose directory no longer exists, so it
# cannot disturb a concurrent run.
git -C "$BASE_REPO" worktree prune
git -C "$BASE_REPO" worktree add --detach "$WT" "$BASE" >/dev/null
# Leaving a registered worktree behind on abort corrupts later runs' bookkeeping.
# EXIT alone is not enough: it does not fire on SIGINT or SIGTERM, so a Ctrl-C or a
# killed sweep left exactly the orphan described above. SIGKILL remains uncoverable,
# which is what the prune above is for.
# Order matters: the agent dies first. Removing the worktree out from under a live
# agent leaves it writing into a deleted directory, and on Ctrl-C it would otherwise
# survive the script entirely — orphaned, idle and unkillable by the next sweep.
_cleanup() {
  watchdog_kill_agent
  git -C "$BASE_REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
}
trap _cleanup EXIT
trap '_cleanup; trap - EXIT; exit 130' INT
trap '_cleanup; trap - EXIT; exit 143' TERM

# A dirty tree silently contaminates the diff. Fail loudly instead.
[ -z "$(git -C "$WT" status --porcelain)" ] || { echo "worktree not clean" >&2; exit 1; }

# --- 2. generate --------------------------------------------------------------
# SPEC.md is the description of intent and nothing else — it is a design document,
# not an instruction. Handed over bare it produced a run that spent 3.6s, made zero
# tool calls, and replied "What would you like me to do with it?". So the prompt is
# a fixed preamble plus the spec verbatim.
#
# The preamble is byte-identical for every model and every repetition, which is what
# keeps it out of the confound list (§10), and the spec itself stays untouched (§6).
# It does exactly two things and deliberately nothing more — no hint about files,
# structure or approach:
#
#   1. States that the task is to implement. There was no instruction at all before.
#   2. Contradicts the spec's own header. This spec opens with "Status: Approved" and
#      "Implementation: landed in branch ... (full test suite green)", which is false
#      in the worktree. Left standing, a model either hunts for that branch or asks
#      what to do.
PREAMBLE='Implement the specification below in this repository.

The specification may describe its own implementation as already complete, landed on
a branch, or verified — it is not. This repository is at the state immediately before
that work; nothing described below exists yet. Implement it.

Work autonomously: nobody is available to answer questions. Make reasonable choices
where the spec is silent and continue.

---

'
# Wrapped in a function so the redirections belong to the agent while run_watched's
# own diagnostics still reach the sweep log instead of being buried in agent.stderr.
_agent() {
  cursor-agent -p \
    --model "$MODEL" \
    --output-format stream-json \
    --workspace "$WT" \
    --force --trust \
    "${PREAMBLE}$(cat "$SPEC_DIR/SPEC.md")" \
    > "$OUT/transcript.jsonl" 2> "$OUT/agent.stderr"
}
GEN_START=$(date +%s)
set +e
# Watched file is the transcript: it is the agent's pulse. A run that goes STALL_S
# without appending to it is killed, and the capture below still runs — a partial diff
# from a stalled run is data, and discarding it would hide the failure mode entirely.
run_watched "$OUT/transcript.jsonl" _agent
AGENT_EXIT=$?
set -e
GEN_ELAPSED=$(( $(date +%s) - GEN_START ))

# --- 3. capture ---------------------------------------------------------------
# `add -A` first so untracked files land in the diff — models routinely create
# files without staging them.
git -C "$WT" add -A
# Diff against BASE explicitly, never against HEAD. A candidate that checks out
# another branch, resets, or commits moves HEAD, and a bare `diff --cached` then
# reports nothing changed — which is how a run that touched 22 files recorded an
# empty diff on the first sweep.
git -C "$WT" diff --cached --binary "$BASE" -- . ":(exclude)$SPEC_PATH" > "$OUT/diff.patch"

# The prompt is an input to the measurement, so keep it with the run rather than
# only in the script — the preamble may change between sweeps.
printf '%s' "${PREAMBLE}" > "$OUT/preamble.txt"

# --- 4. metrics ---------------------------------------------------------------
# Wall clock is a first-class metric here, so it is split by phase: install and
# test-suite time is infrastructure, not model capability, and folding them into
# one number makes a model look slow because yarn was slow.
python3 - "$OUT/transcript.jsonl" "$OUT/metrics.json" "$OUT/diff.patch" \
       "${WATCHDOG_OUTCOME:-}" <<PY
import json, sys
transcript, out, diffpath = sys.argv[1], sys.argv[2], sys.argv[3]
watchdog = sys.argv[4] or None
res, turns = {}, 0
try:
    for line in open(transcript):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "tool_call":
            turns += 1
        elif ev.get("type") == "result":
            res = ev
except FileNotFoundError:
    pass

# The result event carries a \`usage\` block. Normalised to the same field names the
# opencode runner emits so the two populations are comparable.
u = res.get("usage") or {}
tokens = None
if u:
    tokens = {
        "input": u.get("inputTokens"),
        "output": u.get("outputTokens"),
        "reasoning": None,            # cursor-agent does not report it
        "cache_read": u.get("cacheReadTokens"),
        "cache_write": u.get("cacheWriteTokens"),
    }
    tokens["total"] = sum(v for v in tokens.values() if isinstance(v, int))

# DO NOT TREAT \`usage\` AS A RUN TOTAL WITHOUT CHECKING IT.
# On the first sweep 3 of 15 runs reported an outputTokens that cannot possibly have
# produced their own diff — one claimed 226 tokens for a 27 KB diff. It appears to
# cover only the final segment of a run, so anything that got retried, resumed or
# stalled undercounts by orders of magnitude. Rather than discard the field, flag it:
# a diff needs roughly one token per four characters at an absolute minimum, so a run
# that fails that test was segmented, and that is worth knowing on its own (§3 —
# termination reason is load-bearing).
plausible = None
if tokens and isinstance(tokens.get("output"), int):
    try:
        floor = len(open(diffpath).read()) // 4
    except OSError:
        floor = 0
    plausible = tokens["output"] >= floor
    tokens["output_floor_from_diff"] = floor

json.dump({
    "spec": "$SPEC_NAME",
    "model": "$MODEL",
    "rep": $REP,
    "base_sha": "$BASE",
    "cursor_agent_version": "$(cursor-agent --version 2>/dev/null | head -1)",
    "max_turns": $MAX_TURNS,
    "generate_wall_clock_s": $GEN_ELAPSED,
    "verify_wall_clock_s": None,          # filled in below
    "agent_exit_code": $AGENT_EXIT,
    # From the transcript's own result event, so these describe the agent rather
    # than the harness. duration_api_ms vs duration_ms separates time spent
    # waiting on the model from time spent thrashing tools locally.
    # The watchdog wins when it fired: the run did not terminate on its own, so the
    # transcript's own subtype (usually absent — there is no result event) would read
    # as an ordinary finish and quietly enter the scoring as a normal candidate.
    "termination_reason": watchdog or res.get("subtype"),
    "killed_by_watchdog": watchdog,
    "agent_is_error": res.get("is_error"),
    "duration_ms": res.get("duration_ms"),
    "duration_api_ms": res.get("duration_api_ms"),
    "turns": turns,
    "tokens": tokens,
    # False means the reported usage cannot account for this run's own diff — read it
    # as "this run was segmented", not as "the model produced little".
    "tokens_plausible": plausible,
}, open(out, "w"), indent=2)
PY

# --- 5. Tier 0 gate -----------------------------------------------------------
# A candidate that changed nothing is not a candidate. Short-circuit before the
# suite: it is both meaningless to score and expensive to run.
if [ ! -s "$OUT/diff.patch" ]; then
  printf '{\n  "pass": false,\n  "reason": "empty diff — candidate made no changes"\n}\n' \
    > "$OUT/verify.json"
  echo "empty diff — gate failed without running the suite" >&2
  VERIFY_ELAPSED=0
elif [ -x "$SPEC_DIR/verify.sh" ]; then
  VER_START=$(date +%s)
  # Under an absolute cap, and as a tracked child so the signal handler can reach it.
  # A hung suite used to be uncoverable: the generation watchdog ends at the agent, and
  # nothing bounded install + jest after it.
  _gate() {
    ( cd "$WT" && SPEC_DIR="$SPEC_DIR" OUT="$OUT" "$SPEC_DIR/verify.sh" ) > "$OUT/verify.json"
  }
  set +e
  run_capped "$GATE_MAX_S" _gate
  GATE_RC=$?
  set -e
  VERIFY_ELAPSED=$(( $(date +%s) - VER_START ))
  if [ "$GATE_RC" -eq 124 ] && [ "${WATCHDOG_OUTCOME:-}" = over_max ]; then
    # The gate was killed, so whatever landed in verify.json is a truncated capture, not
    # a verdict. Overwrite it with one that says so — an empty or half-written file would
    # be read downstream as an ordinary failure and hide that the suite never finished.
    printf '{\n  "pass": false,\n  "reason": "gate exceeded GATE_MAX_S=%s — suite did not finish"\n}\n' \
      "$GATE_MAX_S" > "$OUT/verify.json"
    GATE_TIMED_OUT=true
  elif [ "$GATE_RC" -ne 0 ]; then
    echo "verify.sh exited non-zero — see verify.json" >&2
  fi
else
  echo "no verify.sh yet — Tier 0 skipped, this run cannot be scored" >&2
  VERIFY_ELAPSED=0
fi

python3 - "$OUT/metrics.json" "$VERIFY_ELAPSED" "${GATE_TIMED_OUT:-false}" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m["verify_wall_clock_s"] = int(sys.argv[2])
# True means the suite was cut off, not that the candidate failed it.
m["gate_timed_out"] = sys.argv[3] == "true"
json.dump(m, open(p, "w"), indent=2)
PY

# --- 6. cleanup AFTER capture, never before ----------------------------------
git -C "$BASE_REPO" worktree remove --force "$WT"
trap - EXIT

echo "$OUT"
