#!/usr/bin/env bash
# One run = one (spec, model, repetition), driven by `opencode` instead of
# `cursor-agent`. Sibling of run-one.sh; that file is untouched.
#
#   usage: ./run-one-opencode.sh <spec-name> <model> [rep]
#          VARIANT=high   reasoning effort passed to --variant (default: high)
#          PTY=1          wrap the agent call in `script` to allocate a pseudo-TTY
#          STALL_S=1800   kill the agent after this long with no transcript growth
#          MAX_S=0        absolute cap on the generation call; 0 = none
#          RETRIES=2      extra attempts when the gateway is unreachable (not when the
#                         model does badly — see the note above the retry loop)
#          BACKOFF_BASE=30 seconds before retrying, times the attempt number
#          GATE_MAX_S=3600 absolute cap on the Tier 0 gate; 0 = none
#          HEARTBEAT_S=300 how often the watchdog reports elapsed/silent time
#
# ON PTY=1 — read this before the first sweep. `opencode run` needs a terminal. With
# stdout and stdin both detached from one it produces no output and never returns:
# it hangs rather than failing, so a sweep would sit there indefinitely with an empty
# log. The sweep redirects this script's output to a file, so whether that is enough
# to break it depends on your shell — if stdin is still your terminal it is usually
# fine, and if you run the sweep detached (nohup, cron, CI) it is not.
#
# The stall watchdog now bounds this: a run with no transcript growth is killed at
# STALL_S and recorded with termination_reason "stalled", so the symptom is a failed run
# instead of a sweep that never returns. If a run dies that way with a zero-byte
# transcript, set PTY=1. That wraps the call in
# `script`, which hands opencode a pseudo-TTY while still capturing stdout. It has to
# be opt-in because `script` itself needs a real terminal to clone settings from and
# fails outright where there is none.
#
# Everything outside the agent invocation is deliberately identical to run-one.sh:
# same isolated worktree, same preamble, same diff capture against BASE, same
# empty-diff guard, same Tier 0 gate, same artifact names. Only by keeping those
# identical is the *harness* the single thing that differs — and the harness is
# exactly what this comparison is measuring (§10).
set -euo pipefail

EVAL_ROOT="${EVAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SPEC_NAME="${1:?spec directory name, e.g. pr-311}"
MODEL="${2:?opencode model, e.g. huawei-modelarts/glm-5.2}"
REP="${3:-0}"
VARIANT="${VARIANT:-high}"   # cursor bakes -high into the model id; match it here
RETRIES="${RETRIES:-2}"
BACKOFF_BASE="${BACKOFF_BASE:-30}"   # seconds, multiplied by the attempt number

# shellcheck source=/dev/null
. "$EVAL_ROOT/lib-watchdog.sh"

SPEC_DIR="$EVAL_ROOT/specs/$SPEC_NAME"
# shellcheck source=/dev/null
. "$SPEC_DIR/config.env"
export REPO BASE_REPO BASE TIP SPEC_PATH TEST_PATHS

# opencode model ids carry slashes, which cannot go in a directory name. Prefix so
# the two harnesses never collide in runs/ and can never be silently averaged
# together by a later reporting script.
MODEL_DIR="opencode__$(printf '%s' "$MODEL" | tr '/' '_')"

OUT="$EVAL_ROOT/runs/$SPEC_NAME/$MODEL_DIR/r$REP"
WT="/tmp/eval/$SPEC_NAME/$MODEL_DIR/r$REP"
mkdir -p "$OUT"
rm -rf "$WT"; mkdir -p "$(dirname "$WT")"

[ -d "${BASE_REPO:-}" ] || {
  echo "config.env has no BASE_REPO — re-run extract-spec.sh (§2)" >&2; exit 1; }

# --- 1. isolated worktree at the frozen base ---------------------------------
# Prune before adding: a sweep killed with SIGKILL leaves this exact path registered
# while its directory is gone, and every later attempt at the same rep then fails on
# `worktree add` with "already registered". Only dead registrations are dropped.
git -C "$BASE_REPO" worktree prune
git -C "$BASE_REPO" worktree add --detach "$WT" "$BASE" >/dev/null
# EXIT does not fire on SIGINT or SIGTERM, which is how a killed sweep orphaned the
# registration above. Cover both; SIGKILL stays the prune's job.
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
[ -z "$(git -C "$WT" status --porcelain)" ] || { echo "worktree not clean" >&2; exit 1; }

# --- 2. generate --------------------------------------------------------------
# Byte-identical to run-one.sh's preamble. If you change one, change both, or the
# two harnesses stop being comparable on the only axis that was supposed to differ.
PREAMBLE='Implement the specification below in this repository.

The specification may describe its own implementation as already complete, landed on
a branch, or verified — it is not. This repository is at the state immediately before
that work; nothing described below exists yet. Implement it.

Work autonomously: nobody is available to answer questions. Make reasonable choices
where the spec is silent and continue.

---

'
# --auto is the counterpart of cursor-agent's --force --trust: without it the agent
# blocks on a permission prompt that nobody is present to answer, and the run hangs
# rather than failing.
#
# Both branches are functions so the redirections stay with the agent while the
# watchdog's own messages still reach the sweep log.
_agent_pty() {
  script -q /dev/null opencode run \
    --dir "$WT" --model "$MODEL" --variant "$VARIANT" --format json --auto \
    "${PREAMBLE}$(cat "$SPEC_DIR/SPEC.md")" \
    > "$OUT/transcript.raw" 2> "$OUT/agent.stderr"
}
_agent() {
  opencode run \
    --dir "$WT" \
    --model "$MODEL" \
    --variant "$VARIANT" \
    --format json \
    --auto \
    "${PREAMBLE}$(cat "$SPEC_DIR/SPEC.md")" \
    > "$OUT/transcript.jsonl" 2> "$OUT/agent.stderr"
}
# Did this attempt fail to reach the model at all? True only when the transcript holds
# an `error` event and not a single completed step — that is the network, not the model.
_unreachable() {
  python3 - "$1" <<'DETECT'
import json, sys
steps = False
retryable = None
try:
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "step_finish":
            steps = True
        elif ev.get("type") == "error":
            data = (ev.get("error") or {}).get("data") or {}
            # The provider often says whether trying again could ever work. Honour it:
            # a pr-1644 run met `Forbidden: Bearer Token has expired` with statusCode 403
            # and isRetryable false, and the retry loop still spent 30s + 60s of backoff
            # on it — three times, for every run, on a credential that only a human can
            # refresh. An expired token is not a flaky gateway.
            retryable = data.get("isRetryable", True)
except OSError:
    pass
sys.exit(0 if (retryable is not None and retryable and not steps) else 1)
DETECT
}

# RETRYING AN UNREACHABLE GATEWAY IS NOT RETRYING A BAD RESULT.
# Repeating a run because the model did poorly would bias the whole measurement — it
# turns k=3 into "best of however many times I felt like trying". Repeating a run that
# never reached the model does not, because there is no model outcome to select on: all
# three attempts of one route on pr-311 came back as a single "unknown certificate
# verification error" with zero steps, and counting those as three losses would have
# scored the network as if it were the model. So the retry is gated on _unreachable,
# never on the diff, the gate, or the score.
#
# Earlier attempts are kept as transcript.attempt-N.jsonl. A run that needed three tries
# to get a connection is worth being able to see afterwards.
GEN_START=$(date +%s)
set +e
# THIS IS THE CASE THE WATCHDOG WAS WRITTEN FOR. On pr-311 an r1 wrote 418 KB in about
# four minutes, stopped at a `step_finish` waiting on a gateway request that never
# returned and never timed out, and then sat there. The sweep shell was eventually
# killed; the opencode process survived it by more than two hours, idle, holding a
# worktree registration. With no timeout anywhere in the chain nothing could end it.
ATTEMPT=0
UNREACHABLE_TRIES=0
while :; do
  if [ "${PTY:-0}" = 1 ]; then
    # Under PTY the transcript is written to .raw and only converted afterwards, so .raw
    # is the file with the pulse — watching transcript.jsonl would see a file that does
    # not exist yet and kill every PTY run at STALL_S.
    run_watched "$OUT/transcript.raw" _agent_pty
    AGENT_EXIT=$?
    # A pseudo-TTY turns line endings into CRLF, which breaks JSONL parsing further
    # down. Strip the CRs; keep the raw capture in case something else needs it.
    tr -d '\r' < "$OUT/transcript.raw" > "$OUT/transcript.jsonl"
  else
    run_watched "$OUT/transcript.jsonl" _agent
    AGENT_EXIT=$?
  fi

  if ! _unreachable "$OUT/transcript.jsonl"; then
    # Either it worked, or it failed in a way retrying cannot fix. Say which, so a
    # 403 on an expired credential is not mistaken for a model that did nothing.
    _fatal="$(python3 - "$OUT/transcript.jsonl" <<'FATAL'
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("type") == "error":
        d = (ev.get("error") or {}).get("data") or {}
        if d.get("isRetryable") is False:
            print(d.get("message") or (ev.get("error") or {}).get("name") or "error")
            break
FATAL
)"
    [ -z "$_fatal" ] || echo "provider says not retryable — giving up: $_fatal" >&2
    break
  fi
  UNREACHABLE_TRIES=$(( UNREACHABLE_TRIES + 1 ))
  [ "$ATTEMPT" -lt "$RETRIES" ] || {
    echo "gateway unreachable on $UNREACHABLE_TRIES attempts — giving up" >&2; break; }

  ATTEMPT=$(( ATTEMPT + 1 ))
  cp "$OUT/transcript.jsonl" "$OUT/transcript.attempt-$ATTEMPT.jsonl"
  # Nothing was generated, so there is nothing to lose by resetting — and a half-written
  # file from a connection that died mid-write would otherwise leak into the diff.
  git -C "$WT" reset --hard -q "$BASE" && git -C "$WT" clean -qfd
  BACKOFF=$(( ATTEMPT * BACKOFF_BASE ))
  printf 'gateway unreachable (attempt %s) — retrying in %ss\n' "$ATTEMPT" "$BACKOFF" >&2
  sleep "$BACKOFF"
done
set -e
GEN_ELAPSED=$(( $(date +%s) - GEN_START ))

# A zero-byte transcript from an agent that "succeeded" is the TTY symptom, not a
# model that had nothing to say. Say so here rather than letting it surface three
# steps later as an unexplained empty diff.
[ -s "$OUT/transcript.jsonl" ] || {
  echo "transcript is empty after ${GEN_ELAPSED}s — opencode most likely had no TTY;" >&2
  echo "  re-run this spec with PTY=1 (see the header of this script)" >&2; }

# --- 3. capture ---------------------------------------------------------------
git -C "$WT" add -A
git -C "$WT" diff --cached --binary "$BASE" -- . ":(exclude)$SPEC_PATH" > "$OUT/diff.patch"
printf '%s' "${PREAMBLE}" > "$OUT/preamble.txt"

# --- 4. metrics ---------------------------------------------------------------
# opencode's --format json is JSONL, one event per line. `step_start` / `step_finish`
# bracket each model round-trip, and `step_finish.part` carries a full token breakdown
# (input, output, reasoning, cache read/write) plus cost.
#
# cursor-agent reports tokens too, in `usage` on its result event — but only for the
# final segment of a run, so it undercounts anything that was retried or resumed. The
# fields normalised here use the same names run-one.sh emits, so the two populations
# are comparable; what opencode adds is `reasoning`, per-step granularity, and a cost
# field (which currently reports zero).
python3 - "$OUT/transcript.jsonl" "$OUT/metrics.json" "${WATCHDOG_OUTCOME:-}" <<PY
import json, sys
transcript, out = sys.argv[1], sys.argv[2]
watchdog = sys.argv[3] or None

events = []
try:
    for line in open(transcript):
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass
except FileNotFoundError:
    pass

def parts(kind):
    return [e.get("part", {}) for e in events
            if isinstance(e, dict) and e.get("type") == kind
            and isinstance(e.get("part"), dict)]

finishes = parts("step_finish")

# An \`error\` event with no step at all is the harness failing to reach the model, not
# the model failing the task — on pr-311 all three runs of one gateway route came back
# as a single 180-byte "unknown certificate verification error" and nothing else. Left
# unlabelled they record as termination_reason null with an empty diff, which is
# indistinguishable from a model that simply did nothing, and they would enter the
# scoring as three losses for a model that was never called. Name the failure so the
# report can exclude it.
errors = [e.get("error") for e in events
          if isinstance(e, dict) and e.get("type") == "error"]
infra_error = None
if errors and not finishes:
    first = errors[0] if isinstance(errors[0], dict) else {}
    data = first.get("data") if isinstance(first.get("data"), dict) else {}
    infra_error = data.get("message") or first.get("name") or "unknown error"

# Summed across steps, not read off the last one. Each step is a separate API call
# that re-sends the context, and the sum is what actually gets billed — which is the
# number §11 wants. CHECK THIS ON THE FIRST REAL RUN: if summed \`input\` comes out
# far larger than the model's context window times the step count, then the field is
# cumulative rather than per-step, the sum is double-counting, and this becomes a max().
tok = {"total": 0, "input": 0, "output": 0, "reasoning": 0,
       "cache_read": 0, "cache_write": 0}
for f in finishes:
    t = f.get("tokens") or {}
    cache = t.get("cache") or {}
    tok["total"]       += t.get("total") or 0
    tok["input"]       += t.get("input") or 0
    tok["output"]      += t.get("output") or 0
    tok["reasoning"]   += t.get("reasoning") or 0
    tok["cache_read"]  += cache.get("read") or 0
    tok["cache_write"] += cache.get("write") or 0

cost = sum(f.get("cost") or 0 for f in finishes)
stamps = [e["timestamp"] for e in events
          if isinstance(e, dict) and isinstance(e.get("timestamp"), int)]
session = next((e.get("sessionID") for e in events
                if isinstance(e, dict) and e.get("sessionID")), None)

# Tool events are deduped by part id: if opencode emits a start/finish pair per call,
# counting event types containing "tool" would report double.
tool_ids = {e["part"].get("id") for e in events
            if isinstance(e, dict) and str(e.get("type", "")).startswith("tool")
            and isinstance(e.get("part"), dict)}

json.dump({
    "spec": "$SPEC_NAME",
    "model": "$MODEL",
    "harness": "opencode",
    "variant": "$VARIANT",
    "rep": $REP,
    "base_sha": "$BASE",
    "opencode_version": "$(opencode --version 2>/dev/null | tail -1)",
    "session_id": session,          # key for \`opencode export <session>\`
    "generate_wall_clock_s": $GEN_ELAPSED,
    "verify_wall_clock_s": None,
    "agent_exit_code": $AGENT_EXIT,
    # Last step wins: earlier steps all finish with "stop" on the way through. Unless
    # the watchdog fired, in which case it is authoritative — a stalled run's last step
    # finished with an ordinary "stop" and would otherwise be scored as a clean finish.
    # Precedence: a watchdog kill is what ended the run, so it wins; an unreachable
    # gateway is next, because there was no run to end.
    "termination_reason": watchdog or ("error" if infra_error else
                                       (finishes[-1].get("reason") if finishes else None)),
    "killed_by_watchdog": watchdog,
    # Non-null means this run measured the network, not the model. Exclude it from
    # pass rates rather than counting it as a failure.
    "infrastructure_error": infra_error,
    # How many attempts died before reaching the model. Non-zero on a run that did
    # eventually succeed means the route is flaky, which is worth reporting even though
    # the run itself is valid.
    "unreachable_attempts": $UNREACHABLE_TRIES,
    # Deliberately NOT called "turns". cursor-agent's \`turns\` counts tool_call events;
    # \`steps\` counts model round-trips. Different units — naming both "turns" would
    # invite a cross-harness comparison that does not mean anything.
    "steps": len(parts("step_start")) or None,
    "tool_calls": len(tool_ids) or None,
    "tokens": tok if finishes else None,
    "cost": cost if finishes else None,
    "duration_ms": (max(stamps) - min(stamps)) if len(stamps) > 1 else None,
}, open(out, "w"), indent=2)
PY

# --- 5. Tier 0 gate -----------------------------------------------------------
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
