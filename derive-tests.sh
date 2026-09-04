#!/usr/bin/env bash
# §1 / §12 step 2 — establishes the Tier 0 gate for one spec, then writes its
# verify.sh.
#
#   usage: ./derive-tests.sh [spec-name]       (or: export SPEC=pr-1234)
#          TEST_CMD=… / INSTALL_CMD=… to override the yarn defaults
#
# Runs the suite three times and records what happened. The three results are
# preconditions, not statistics: if any of them comes out wrong, this spec cannot
# measure anything and the sweep should not run.
#
#   A. base, without the reference tests   -> must PASS
#      A red suite at base means every candidate inherits failures it did not
#      cause, and Tier 0 stops distinguishing anything.
#
#   B. base, with the reference tests      -> must FAIL
#      THE VACUITY CHECK, and the one worth understanding. If the shipped tests
#      already pass before the change exists, they do not test the change: the
#      task is satisfied at base, every model "succeeds" by doing nothing, and
#      the eval silently measures nothing at all.
#
#   C. tip (the reference itself)          -> must PASS
#      Sanity: the shipped code passes its own tests.
#
# Given A, B and C, the gate is simply "whole suite green with the reference tests
# restored" — that single condition subsumes both the fail->pass and pass->pass
# sets from §1, and needs no per-test-id parsing to be exact.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="${EVAL_ROOT:-$HERE}"
SPEC_NAME="${1:-${SPEC:-}}"
[ -n "$SPEC_NAME" ] || { echo "usage: $(basename "$0") <spec-name>   (or: export SPEC=pr-1234)" >&2; exit 1; }
TEST_CMD="${TEST_CMD:-corepack yarn test}"
INSTALL_CMD="${INSTALL_CMD:-corepack yarn ci}"

SPEC_DIR="$EVAL_ROOT/specs/$SPEC_NAME"
[ -f "$SPEC_DIR/config.env" ] || {
  echo "no spec at $SPEC_DIR — run extract-spec.sh first" >&2; exit 1; }
# shellcheck source=/dev/null
. "$SPEC_DIR/config.env"

[ -d "${BASE_REPO:-}" ] || {
  echo "config.env has no BASE_REPO — re-run extract-spec.sh (§2)" >&2; exit 1; }

WT="/tmp/eval-derive/$SPEC_NAME"
rm -rf "$WT"; mkdir -p "$(dirname "$WT")"
# A and B run from base-repo — the same cut-at-BASE repository the candidates get.
# Measuring the preconditions in a richer environment than the one under test would
# validate something the sweep never actually runs in.
git -C "$BASE_REPO" worktree add --detach "$WT" "$BASE" >/dev/null
trap 'git -C "$BASE_REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true;
      git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT

cd "$WT"
printf 'installing dependencies (%s)\n' "$INSTALL_CMD"
eval "$INSTALL_CMD" > "$SPEC_DIR/derive-install.log" 2>&1 || {
  echo "install failed at base — see $SPEC_DIR/derive-install.log" >&2; exit 1; }

run_suite() {  # $1 = label; echoes the exit code, never aborts
  local label="$1" rc=0
  eval "$TEST_CMD" > "$SPEC_DIR/derive-$label.log" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# Which test files the reference itself had to change for the feature to exist. Run 1
# does NOT restore these over the candidate's versions — see the note in verify.sh.
# Derived from reference-tests.patch, which extract-spec.sh already produced, so
# adding it here avoids a re-extraction.
grep -E '^\+\+\+ b/' "$SPEC_DIR/reference-tests.patch" \
  | sed 's|^+++ b/||' | sort -u > "$SPEC_DIR/reference-touched-tests.txt"
printf 'reference touched %s test files (excluded from run 1 restore)\n' \
  "$(grep -c . "$SPEC_DIR/reference-touched-tests.txt" || true)"

printf 'A. base, without reference tests ... '
RC_A="$(run_suite base-clean)"
printf '%s\n' "$([ "$RC_A" -eq 0 ] && echo "pass" || echo "FAIL (exit $RC_A)")"

printf 'B. base, with reference tests    ... '
# Same archive the gate uses, so precondition B exercises the identical mechanism
# rather than a git checkout the candidate's repo could never perform.
tar -xf "$SPEC_DIR/reference-tests.tar"
RC_B="$(run_suite base-with-tests)"
printf '%s\n' "$([ "$RC_B" -ne 0 ] && echo "fails, as required" || echo "PASSES — vacuous")"

printf 'C. reference tip                 ... '
# C is the only step that needs the reference commit, so it is the only one that
# touches the full repo. Harness work, never a candidate.
git checkout . >/dev/null 2>&1 || true
cd /
git -C "$BASE_REPO" worktree remove --force "$WT" >/dev/null
git -C "$REPO" worktree add --detach "$WT" "$TIP" >/dev/null
cd "$WT"
eval "$INSTALL_CMD" >> "$SPEC_DIR/derive-install.log" 2>&1 || true
RC_C="$(run_suite tip)"
printf '%s\n' "$([ "$RC_C" -eq 0 ] && echo "pass" || echo "FAIL (exit $RC_C)")"

cat > "$SPEC_DIR/tests.json" <<JSON
{
  "test_cmd": "$TEST_CMD",
  "install_cmd": "$INSTALL_CMD",
  "base_clean_exit": $RC_A,
  "base_with_reference_tests_exit": $RC_B,
  "tip_exit": $RC_C,
  "usable": $( [ "$RC_A" -eq 0 ] && [ "$RC_B" -ne 0 ] && [ "$RC_C" -eq 0 ] && echo true || echo false ),
  "derived_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

FATAL=0
[ "$RC_A" -eq 0 ] || { echo; echo "A failed: the suite is already red at base. Candidates would" >&2
  echo "  inherit failures they did not cause. Fix the base or pick another PR." >&2; FATAL=1; }
[ "$RC_B" -ne 0 ] || { echo; echo "B passed: the reference tests pass WITHOUT the change. They do not" >&2
  echo "  test this PR, so every model passes by doing nothing. This spec measures" >&2
  echo "  nothing — pick a PR whose tests actually exercise the new behaviour." >&2; FATAL=1; }
[ "$RC_C" -eq 0 ] || { echo; echo "C failed: the shipped code does not pass its own tests here. Usually a" >&2
  echo "  missing service, fixture or env var — the suite needs more than $INSTALL_CMD." >&2; FATAL=1; }
[ "$FATAL" -eq 0 ] || { echo; echo "tests.json written with usable=false; do not sweep." >&2; exit 1; }

# --- the gate ----------------------------------------------------------------
cat > "$SPEC_DIR/verify.sh" <<VERIFY
#!/usr/bin/env bash
# Tier 0 gate for $SPEC_NAME. Generated by derive-tests.sh — edit freely.
# Runs in the candidate's worktree; emits JSON on stdout; exit 0 iff the gate passes.
set -uo pipefail

TEST_CMD='$TEST_CMD'
INSTALL_CMD='$INSTALL_CMD'
SPEC_DIR="\${SPEC_DIR:?}"
OUT="\${OUT:-.}"

# Yarn Berry with PnP never creates node_modules, so checking for that directory
# alone would reinstall on every run. Check for either linker's artifacts.
if [ ! -d node_modules ] && [ ! -f .pnp.cjs ] && [ ! -f .pnp.loader.mjs ]; then
  eval "\$INSTALL_CMD" > "\$OUT/install.log" 2>&1
fi

# Restore a test set from an archive and assert it landed. Unconditional extraction
# is what neutralises a candidate that weakened or deleted tests to pass. The
# assertion exists because the previous version used
# \`git checkout … 2>/dev/null || true\` with an unquoted pathspec: a restore that
# silently did nothing left the suite running without the new tests — green by
# definition, and recorded as a pass.
restore() {   # \$1 = archive, \$2.. = paths to leave alone
  local arch="\$1"; shift
  local ex=() p
  for p in "\$@"; do ex+=(--exclude="\$p"); done
  # \${ex[@]+...} and not "\${ex[@]}": bash 3.2 under \`set -u\` treats expanding an
  # empty array as an unbound variable and aborts. Run 2 passes no exclusions at all,
  # so the plain form crashed the gate before the reference tests ever ran.
  tar -xf "\$SPEC_DIR/\$arch" \${ex[@]+"\${ex[@]}"} || return 1
  while IFS= read -r f; do
    case "\$f" in */) continue ;; esac
    for p in "\$@"; do [ "\$f" = "\$p" ] && continue 2; done
    [ -f "\$f" ] || { echo "not restored from \$arch: \$f" >&2; return 1; }
  done < <(tar -tf "\$SPEC_DIR/\$arch")
}

# --- run 1: regression. THIS is the gate ---------------------------------------
# The suite as it stood before the PR, EXCEPT the test files the reference itself had
# to change. Answers "did the candidate break anything that already worked?"
#
# Why the exception: restoring base tests unconditionally makes run 1 unpassable for
# any candidate that legitimately updates a mock. On pr-311 the implementation adds a
# call to lmClient.listStorefrontRoles(); the base version of users.test.ts mocks
# lmClient without that method, so the base test throws TypeError against ANY correct
# implementation. The reference proves the update is legitimate rather than cheating —
# it changed those same files, 17 mock additions' worth. Forcing the base version back
# reverts a fix the reference also had to make, and then fails the candidate for it.
#
# The reference's own file list is what bounds this. Files it did not touch are still
# restored by force, so a candidate cannot weaken an unrelated test to pass; files it
# did touch are conceded, because the feature cannot exist without changing them.
REF_TOUCHED=()
if [ -f "\$SPEC_DIR/reference-touched-tests.txt" ]; then
  while IFS= read -r f; do [ -n "\$f" ] && REF_TOUCHED+=("\$f"); done \
    < "\$SPEC_DIR/reference-touched-tests.txt"
fi
restore base-tests.tar "\${REF_TOUCHED[@]+"\${REF_TOUCHED[@]}"}" || {
  echo '{"pass": false, "reason": "could not restore base tests"}'; exit 1; }
REG_OUT="\$(eval "\$TEST_CMD" 2>&1)"; REG_RC=\$?
printf '%s' "\$REG_OUT" > "\$OUT/verify-regression.log"

# --- run 2: reference contract. A SIGNAL, not a gate ---------------------------
# The suite as it shipped. Answers "did the candidate match the reference's
# contract?" — informative, but it cannot fail the run: these tests import internal
# symbols by name, so a divergence here may be nothing more than a different
# internal name for identical behaviour. That call belongs to the judge (§6), which
# receives this result in verify.json.
# Run 2 restores everything, with no exception: here the point IS the reference's own
# tests, so conceding files to the candidate would defeat the measurement.
restore reference-tests.tar || {
  echo '{"pass": false, "reason": "could not restore reference tests"}'; exit 1; }
REF_OUT="\$(eval "\$TEST_CMD" 2>&1)"; REF_RC=\$?
printf '%s' "\$REF_OUT" > "\$OUT/verify-reference.log"

python3 - "\$REG_RC" "\$REF_RC" <<'PY'
import json, sys
reg, ref = int(sys.argv[1]), int(sys.argv[2])
print(json.dumps({
    # Tier 0 verdict. Only the regression run gates.
    "pass": reg == 0,
    "regression": {"passed": reg == 0, "exit_code": reg},
    "reference_tests": {"passed": ref == 0, "exit_code": ref},
}, indent=2))
PY
exit \$REG_RC
VERIFY
chmod +x "$SPEC_DIR/verify.sh"

printf '\nall three preconditions hold — spec is usable\n'
printf '  %s\n  %s\n' "$SPEC_DIR/tests.json" "$SPEC_DIR/verify.sh"
printf '\n  next: calibrate.sh %s, then sweep.sh %s\n\n' "$SPEC_NAME" "$SPEC_NAME"
