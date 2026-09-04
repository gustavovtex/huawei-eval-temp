# Stall watchdog for the generation call. Sourced by run-one.sh and
# run-one-opencode.sh — the two must behave identically here, and a shared file is
# what enforces that.
#
#   STALL_S=1800   kill the agent after this many seconds with no transcript growth
#   MAX_S=0        absolute cap on the whole call; 0 = none
#   POLL_S=30      how often the watchdog looks
#
# WHY STALL AND NOT TIMEOUT
# An absolute timeout has to be enormous to be safe: the opencode r0 on pr-311 took
# 1778s and `gpt-5.6-terra-high` r2 took 6103s, and both completed and were scored. A
# cap generous enough for those is too generous to catch anything. Silence, on the
# other hand, is unambiguous — the run that hung sat 7980s without writing a byte,
# stopped at a `step_finish` boundary waiting on a gateway request that never returned
# nor timed out. Both agents emit events continuously while working (the glm r0 alone
# produced 8331 `thinking` events; opencode streams `step_*` and tool events), so
# transcript growth is a reliable pulse and 30 minutes of flatline is not a slow model.
#
# WHY NOT `timeout`
# It does not exist on macOS, and `gtimeout` needs coreutils. This is a poll loop.
#
# WHY NOT A PROCESS-GROUP KILL
# `set -m` would put the agent in its own process group, which is the tidy way to kill
# a tree — but it also detaches it from the terminal's foreground group, and an agent
# that touches stdin would then take SIGTTIN and stop dead. That changes the
# environment the model runs in, which is precisely the kind of harness variation §10
# exists to prevent. So the child is started exactly as before and the tree is walked
# by parentage instead.

STALL_S="${STALL_S:-1800}"
MAX_S="${MAX_S:-0}"
POLL_S="${POLL_S:-30}"
HEARTBEAT_S="${HEARTBEAT_S:-300}"    # 0 disables
# The gate gets an absolute cap, not a stall detector: unlike generation its duration is
# predictable (the worst observed run of the pr-311 suite was 978s) and it streams
# nothing while running — verify.sh captures the test output into a variable and only
# writes the log after the command returns, so there is no pulse to watch.
GATE_MAX_S="${GATE_MAX_S:-3600}"     # 0 disables

# Set by run_watched: "" on a normal exit, else "stalled" or "over_max".
WATCHDOG_OUTCOME=""
# PID of the agent while it is running, empty otherwise. Exported so the caller's
# signal handler can take the agent down with it: a Ctrl-C that cleans up the worktree
# but leaves the agent running produces exactly the orphan this watchdog exists to
# prevent — a process with no parent, holding no lock, that nothing will ever stop.
WATCHDOG_PID=""

_wd_pulse() {   # $1 = file; mtime+size, empty when absent
  stat -f '%m %z' "$1" 2>/dev/null || true
}

_wd_tree() {    # $1 = pid; echoes the subtree, leaves first
  local kid
  for kid in $(pgrep -P "$1" 2>/dev/null || true); do _wd_tree "$kid"; done
  printf '%s\n' "$1"
}

# `kill -0` is not a liveness test on its own: a child that has died but not yet been
# reaped is a zombie, and signalling a zombie succeeds. Using it alone made the grace
# loop below spin its full ten seconds on a process that was already dead, and a
# Ctrl-C then took twelve seconds to be felt. Ask ps for the state instead.
_wd_alive() { # $1 = pid
  local st
  st="$(ps -o state= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -n "$st" ] && [ "${st#Z}" = "$st" ]
}

_wd_kill() {    # $1 = pid; TERM the tree, then KILL whatever is still standing
  local pids sig p waited
  pids="$(_wd_tree "$1")"
  for sig in TERM KILL; do
    for p in $pids; do kill -"$sig" "$p" 2>/dev/null || true; done
    [ "$sig" = KILL ] && return
    waited=0
    while _wd_alive "$1" && [ "$waited" -lt 10 ]; do
      sleep 1; waited=$(( waited + 1 ))
    done
    _wd_alive "$1" || return
    # Re-read the tree: a child may have outlived the parent's TERM.
    pids="$(_wd_tree "$1")"
  done
}

# run_watched <file-to-watch> <cmd> [args...]
# Returns the command's exit status, or 124 if the watchdog killed it. MUST be called
# with errexit off — it inspects failing exit codes on purpose.
run_watched() {
  local watch="$1"; shift
  WATCHDOG_OUTCOME=""

  # ANNOUNCE, ALWAYS. A run of pr-1644 sat 89 minutes with a frozen transcript and this
  # watchdog never fired; the log held one line from git and nothing else, so there was
  # no way to tell whether the loop was even running, what STALL_S it had resolved to,
  # or which file it was watching. The watchdog now says all three before it starts, and
  # heartbeats while it waits. Diagnosing the next occurrence should cost one glance at
  # the log, not a post-mortem on a process that has already been killed.
  printf 'watchdog: STALL_S=%s MAX_S=%s POLL_S=%s watching %s\n' \
    "$STALL_S" "$MAX_S" "$POLL_S" "$watch" >&2

  "$@" &
  local pid=$! rc=0 now started last_seen prev pulse beat last_poll gap drift
  WATCHDOG_PID="$pid"
  started=$(date +%s); last_seen=$started; beat=$started; last_poll=$started
  prev="$(_wd_pulse "$watch")"

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$POLL_S"
    now=$(date +%s)

    # SUSPENDED TIME IS NOT SILENCE. On a laptop the machine sleeps, and then wall clock
    # and awake time stop agreeing: a pr-1644 run showed 2316s between two consecutive
    # polls because macOS had suspended three times for 2295s total. Counting that as
    # silence is wrong in both directions — it would kill a run that was merely
    # suspended, and here it did the opposite: the agent woke up, wrote its error in the
    # same poll, and reset last_seen, so a run that had made no progress for 39 minutes
    # looked like "0s silent". A gap far larger than POLL_S can only be the clock
    # jumping, since nothing else can delay this loop that much, so credit it back.
    gap=$(( now - last_poll ))
    if [ "$gap" -gt $(( POLL_S * 3 + 60 )) ]; then
      drift=$(( gap - POLL_S ))
      last_seen=$(( last_seen + drift ))
      started=$(( started + drift ))
      beat=$(( beat + drift ))
      printf 'watchdog: clock jumped %ss (machine suspended?) — not counted as silence\n' \
        "$drift" >&2
    fi
    last_poll=$now

    pulse="$(_wd_pulse "$watch")"
    if [ "$pulse" != "$prev" ]; then prev="$pulse"; last_seen=$now; fi

    # A heartbeat proves the loop is alive and shows the numbers it is deciding on. If a
    # future run hangs and these lines are absent, the loop died; if they are present
    # with the silence resetting, the transcript was trickling and STALL_S never elapsed.
    if [ "$HEARTBEAT_S" -gt 0 ] && [ $(( now - beat )) -ge "$HEARTBEAT_S" ]; then
      beat=$now
      printf 'watchdog: %ss elapsed, %ss silent (limit %s)\n' \
        "$(( now - started ))" "$(( now - last_seen ))" "$STALL_S" >&2
    fi

    if [ $(( now - last_seen )) -ge "$STALL_S" ]; then
      WATCHDOG_OUTCOME=stalled; break
    fi
    if [ "$MAX_S" -gt 0 ] && [ $(( now - started )) -ge "$MAX_S" ]; then
      WATCHDOG_OUTCOME=over_max; break
    fi
  done

  if [ -n "$WATCHDOG_OUTCOME" ]; then
    printf 'watchdog: %s after %ds (no output for %ds) — killing the agent\n' \
      "$WATCHDOG_OUTCOME" "$(( $(date +%s) - started ))" "$(( $(date +%s) - last_seen ))" >&2
    # Dropped from the job table before the signal, so bash does not print its own
    # "Terminated: 15" notice naming a line inside this file — which reads like a
    # harness crash in the sweep log when it is in fact the intended outcome. The
    # process is still a child and still gets reaped; only the bookkeeping is gone,
    # which is why the wait below becomes a poll.
    disown "$pid" 2>/dev/null || true
    _wd_kill "$pid"
    while _wd_alive "$pid"; do sleep 1; done
    rc=124
  else
    wait "$pid"; rc=$?
  fi
  WATCHDOG_PID=""
  return $rc
}

# watchdog_kill_agent — for a caller's INT/TERM handler. No-op when nothing is running.
watchdog_kill_agent() {
  [ -n "${WATCHDOG_PID:-}" ] || return 0
  _wd_kill "$WATCHDOG_PID"
  WATCHDOG_PID=""
}

# run_capped <seconds> <cmd> [args...]
# Absolute cap, for a phase that produces no streaming output to watch. Returns the
# command's status, or 124 if the cap was hit; sets WATCHDOG_OUTCOME to over_max then.
# Shares _wd_kill with run_watched, so the whole process tree goes — a capped gate must
# not leave `yarn` and `jest` behind.
#
# It also puts the gate under WATCHDOG_PID, which is what finally makes Ctrl-C work
# during the suite: the caller's INT handler kills whatever WATCHDOG_PID names, and
# before this the gate was not tracked at all, so a Ctrl-C mid-suite was deferred until
# jest finished — up to sixteen minutes on pr-311.
run_capped() {
  local cap="$1"; shift
  WATCHDOG_OUTCOME=""
  [ "$cap" -gt 0 ] || { "$@"; return $?; }

  printf 'gate: cap %ss\n' "$cap" >&2
  "$@" &
  local pid=$! rc=0 started
  WATCHDOG_PID="$pid"
  started=$(date +%s)

  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    [ $(( $(date +%s) - started )) -ge "$cap" ] || continue
    WATCHDOG_OUTCOME=over_max
    printf 'gate: exceeded %ss — killing it\n' "$cap" >&2
    disown "$pid" 2>/dev/null || true
    _wd_kill "$pid"
    while _wd_alive "$pid"; do sleep 1; done
    WATCHDOG_PID=""
    return 124
  done
  wait "$pid"; rc=$?
  WATCHDOG_PID=""
  return $rc
}
