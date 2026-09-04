#!/usr/bin/env bash
# Turns a merged PR into a spec directory. Steps 1–2 of §12; run once per spec.
#
#   usage: ./extract-spec.sh <pr-number> <repo> <spec-path> <test-pathspecs>
#
#     <pr-number>  the PR that shipped the change
#     <repo>       local clone path, owner/name, or a git URL
#     <spec-path>  path of the spec file inside the repo, e.g. docs/SPEC.md
#     <test-pathspecs>  quoted, space-separated git pathspecs; defaults to
#                       node/__tests__/ . A trailing-slash directory matches
#                       everything beneath it, including files sitting directly
#                       in it — '__tests__/**/*.ts' does NOT, because git's
#                       default matcher needs at least one slash after the **.
#
# This repo does NOT squash-merge, so a PR is a *range* of commits, not one
# commit. The eval only ever needed (base state, net change), and a range diff
# supplies both — but the base has to be derived from the merge topology rather
# than assumed to be SHA^. Strategy is detected per PR, so a repo that mixes
# merge-commit and rebase merges is handled without configuration.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="${EVAL_ROOT:-$HERE}"
PR="${1:?PR number}"
REPO_IN="${2:?local clone path, owner/name, or git URL}"
SPEC_PATH="${3:?path of the spec file inside the repo}"
TEST_PATHS="${4:-${TEST_PATHS:-node/__tests__/}}"

# gh lives in /opt/homebrew/bin, which is absent from some non-interactive PATHs.
GH="${GH:-$(command -v gh || true)}"
[ -x "${GH:-}" ] || for c in /opt/homebrew/bin/gh /usr/local/bin/gh; do
  [ -x "$c" ] && GH="$c" && break
done
[ -x "${GH:-}" ] || { echo "gh not found — set GH=/path/to/gh" >&2; exit 1; }

# --- resolve the repo to a local clone ---------------------------------------
if [ -d "$REPO_IN/.git" ]; then
  REPO="$(cd "$REPO_IN" && pwd)"
else
  REPO="$EVAL_ROOT/.repos/$(basename "${REPO_IN%.git}")"
  mkdir -p "$(dirname "$REPO")"
  if [ ! -d "$REPO/.git" ]; then
    case "$REPO_IN" in
      *://*|*@*:*) git clone --quiet "$REPO_IN" "$REPO" ;;
      */*)         "$GH" repo clone "$REPO_IN" "$REPO" -- --quiet ;;
      *) echo "cannot interpret repo: $REPO_IN" >&2; exit 1 ;;
    esac
  fi
fi
git -C "$REPO" fetch --quiet --all --prune --tags

# --- PR metadata (gh is the source of truth for merge state) -------------------
mkdir -p "$EVAL_ROOT/specs/pr-$PR"
SPEC_DIR="$EVAL_ROOT/specs/pr-$PR"

"$GH" pr view "$PR" --repo "$(git -C "$REPO" remote get-url origin)" \
  --json number,title,url,state,mergedAt,mergeCommit,baseRefName,commits,files \
  > "$SPEC_DIR/pr.json"

gh_field() { "$GH" pr view "$PR" --repo "$(git -C "$REPO" remote get-url origin)" \
  --json "$1" --jq "$2"; }

STATE="$(gh_field state .state)"
[ "$STATE" = "MERGED" ] || { echo "PR #$PR is $STATE, not MERGED — nothing shipped" >&2; exit 1; }

TIP="$(gh_field mergeCommit '.mergeCommit.oid // ""')"
[ -n "$TIP" ] || { echo "PR #$PR has no mergeCommit — cannot locate it on any branch" >&2; exit 1; }
NCOMMITS="$(gh_field commits '.commits | length')"
BASE_BRANCH="$(gh_field baseRefName .baseRefName)"

git -C "$REPO" cat-file -e "$TIP^{commit}" 2>/dev/null || {
  echo "merge commit $TIP not present locally; fetching" >&2
  git -C "$REPO" fetch --quiet origin "$TIP" || {
    echo "could not fetch $TIP" >&2; exit 1; }
}

# --- derive the base from the merge topology ----------------------------------
# 2 parents  → merge commit: mainline parent is the pre-PR state, tip is the merge.
# 1 parent   → rebase merge: the PR's commits were replayed contiguously onto the
#              mainline, so walking back N commits lands on the pre-PR state.
NPARENTS=$(( $(git -C "$REPO" rev-list --parents -n 1 "$TIP" | wc -w) - 1 ))
case "$NPARENTS" in
  2) STRATEGY="merge_commit"; BASE="$(git -C "$REPO" rev-parse "$TIP^1")" ;;
  1) STRATEGY="rebase_or_squash"; BASE="$(git -C "$REPO" rev-parse "$TIP~$NCOMMITS")" ;;
  *) echo "merge commit $TIP has $NPARENTS parents — unhandled topology" >&2; exit 1 ;;
esac

# --- cross-validate the range against what GitHub says the PR changed ---------
# A wrong BASE yields a task that is already partly done, and nothing downstream
# reveals it — the models just look better than they are. This is the check that
# catches it: the file set of BASE..TIP must equal the PR's own file set.
"$GH" pr view "$PR" --repo "$(git -C "$REPO" remote get-url origin)" \
  --json files --jq '.files[].path' | sort -u > "$SPEC_DIR/.files-github"
git -C "$REPO" diff --name-only "$BASE..$TIP" | sort -u > "$SPEC_DIR/.files-range"
if ! diff -q "$SPEC_DIR/.files-github" "$SPEC_DIR/.files-range" >/dev/null; then
  echo "BASE..TIP does not match the PR's file set — derived base is wrong." >&2
  echo "  strategy=$STRATEGY base=$BASE tip=$TIP commits=$NCOMMITS" >&2
  diff "$SPEC_DIR/.files-github" "$SPEC_DIR/.files-range" | head -30 >&2
  echo "  (< only on GitHub, > only in the range)" >&2
  exit 1
fi
rm -f "$SPEC_DIR/.files-github" "$SPEC_DIR/.files-range"

# --- the spec file must be readable at the tip --------------------------------
git -C "$REPO" cat-file -e "$TIP:$SPEC_PATH" 2>/dev/null || {
  echo "no such file at $TIP: $SPEC_PATH" >&2; exit 1; }

if git -C "$REPO" diff --name-only "$BASE..$TIP" | grep -qxF "$SPEC_PATH"; then
  SPEC_ORIGIN="shipped_in_pr"
else
  SPEC_ORIGIN="predates_pr"
fi

# --- write the spec directory -------------------------------------------------
printf '%s\n' "$BASE" > "$SPEC_DIR/base.sha"
git -C "$REPO" show "$TIP:$SPEC_PATH" > "$SPEC_DIR/SPEC.md"

read -ra TP <<< "$TEST_PATHS"
EXCLUDES=()
for p in "$SPEC_PATH" "${TP[@]}"; do
  case "$p" in
    # Already carries magic: fold `exclude` into the existing list. Writing
    # ':(exclude):(glob)X' instead is accepted by git and silently excludes
    # nothing, which would leak test files into reference-impl.patch.
    :\(*\)*) EXCLUDES+=(":(exclude,${p#:(}") ;;
    *)        EXCLUDES+=(":(exclude)$p") ;;
  esac
done

git -C "$REPO" diff "$BASE..$TIP" -- "${TP[@]}" > "$SPEC_DIR/reference-tests.patch"
git -C "$REPO" diff "$BASE..$TIP" -- . "${EXCLUDES[@]}" > "$SPEC_DIR/reference-impl.patch"

# --- isolated base repo: the candidate must not be able to read the answer ------
# Candidates run in worktrees. Cut them from the working clone and they inherit
# every ref it has — including the branch that holds this PR's implementation and
# the merge commit itself. That is not hypothetical: on the first sweep, two of
# three runs found `feat/...` in the refs, concluded the work was already done, and
# returned an empty diff.
#
# Fetching a single SHA into a fresh bare repo copies only what is reachable FROM
# that commit, so nothing after BASE exists at all. History up to BASE is intact,
# so a model can still read `git log` for conventions.
BASE_REPO="$SPEC_DIR/base-repo"
rm -rf "$BASE_REPO"
git init --bare -q "$BASE_REPO"
git -C "$BASE_REPO" fetch -q --no-tags "$REPO" "${BASE}:refs/heads/eval-base"

# Belt and braces: prove the answer is gone rather than assuming the fetch was
# tight. A silent failure here reproduces the exact bug this replaces.
if git -C "$BASE_REPO" cat-file -e "$TIP" 2>/dev/null; then
  echo "base-repo still reaches the reference commit $TIP — refusing to continue" >&2
  exit 1
fi
git -C "$BASE_REPO" cat-file -e "$BASE" 2>/dev/null || {
  echo "base-repo is missing the base commit $BASE" >&2; exit 1; }

# Two test archives, because Tier 0 runs the suite twice with different sets (§1).
# Shipped as plain files rather than pulled from git at verify time: the reference
# commit is unreachable from the candidate's repo by design, so there is no ref to
# check out and no path back to the implementation.
#
#   base-tests      the suite as it stood BEFORE the PR — the hard gate (regression)
#   reference-tests the suite as it shipped — a signal for the judge, not a gate
#
# The split exists because the reference tests are white-box: they import internal
# symbols by name. On pr-311 exactly one of the 35 they import is both new and
# unnamed in the spec (`SURFACES`), so requiring them would fail a candidate for
# choosing a different internal name — the one thing §6 says never to penalise.
git -C "$REPO" archive "$BASE" -- "${TP[@]}" > "$SPEC_DIR/base-tests.tar"
git -C "$REPO" archive "$TIP"  -- "${TP[@]}" > "$SPEC_DIR/reference-tests.tar"

cat > "$SPEC_DIR/config.env" <<ENV
REPO='$REPO'
BASE_REPO='$BASE_REPO'
BASE='$BASE'
TIP='$TIP'
SPEC_PATH='$SPEC_PATH'
TEST_PATHS='$TEST_PATHS'
ENV

cat > "$SPEC_DIR/provenance.json" <<JSON
{
  "pr": $PR,
  "base_branch": "$BASE_BRANCH",
  "merge_strategy": "$STRATEGY",
  "pr_commit_count": $NCOMMITS,
  "base_sha": "$BASE",
  "tip_sha": "$TIP",
  "spec_path": "$SPEC_PATH",
  "spec_origin": "$SPEC_ORIGIN",
  "extracted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

# --- report -------------------------------------------------------------------
printf '\n%s\n' "$SPEC_DIR"
printf '  PR #%-6s %s\n' "$PR" "$(gh_field title .title)"
printf '  strategy   %s (%s commits, onto %s)\n' "$STRATEGY" "$NCOMMITS" "$BASE_BRANCH"
printf '  base       %s\n' "$BASE"
printf '  tip        %s\n' "$TIP"
printf '  spec       %s (%s)\n' "$SPEC_PATH" "$SPEC_ORIGIN"
printf '  impl diff  %s files\n' \
  "$(git -C "$REPO" diff --name-only "$BASE..$TIP" -- . "${EXCLUDES[@]}" | grep -c . || true)"
printf '  test diff  %s files\n' \
  "$(git -C "$REPO" diff --name-only "$BASE..$TIP" -- "${TP[@]}" | grep -c . || true)"
printf '  base-repo  %s, %s commits, 1 ref, TIP unreachable\n' \
  "$(du -sh "$BASE_REPO" | cut -f1)" "$(git -C "$BASE_REPO" rev-list --count eval-base)"
printf '  test tars  %s at base, %s at reference\n' \
  "$(tar -tf "$SPEC_DIR/base-tests.tar" | grep -vc '/$' || true)" \
  "$(tar -tf "$SPEC_DIR/reference-tests.tar" | grep -vc '/$' || true)"

if [ ! -s "$SPEC_DIR/reference-tests.patch" ]; then
  printf '\n  !! test diff is empty — either $TEST_PATHS is wrong for this repo, or\n'
  printf '     the PR shipped no tests. Either way there is no Tier 0 gate to build\n'
  printf '     from, and this spec cannot be scored as designed (§1).\n'
fi

printf '\n  next: derive tests.json, then write verify.sh (§1, §12 step 2)\n\n'
