#!/usr/bin/env bash
# Builds anon/<spec>/ from runs/<spec>/ — §5. Only runs that cleared Tier 0 are
# copied; the rest scored zero and never reach the judge (§1).
#
#   usage: ./blind.sh [spec-name]              (or: export SPEC=pr-1234)
#
# Deterministic and idempotent: the label for a (spec, model, rep) is a hash, so
# re-running produces the same mapping. The hash is salted with the spec name so
# labels don't correlate across specs — otherwise a reader who deanonymised one
# spec would have deanonymised every spec.
#
# THE LABEL SPACE IS 100, NOT 1296. `shasum` emits lowercase hex, so the `A-Z` in the
# tr below never matches and only digits survive. At 19 candidates the birthday odds of
# a collision are about 85%, and pr-311 duly collided: gpt-5.6-terra-high/r2 and
# opencode__vtex-glm_huawei_glm-5.2/r0 both hash to 91. Widening the alphabet was the
# obvious fix and the wrong one — it renames every existing label, orphaning judged
# verdicts already published against them. So instead:
#
#   1. A label already recorded in anon/<spec>.mapping.json is REUSED for its own
#      (model, rep). Labels are therefore stable across sweeps, and a verdict keyed to
#      one stays valid when the next sweep adds runs.
#   2. A label ever issued is never reissued to a different run, even if the original
#      no longer clears the gate — it moves to "retired" instead. A label that meant
#      two different things at two points in time would silently mismatch old verdicts.
#   3. A new run whose hash is taken probes deterministically: hash(spec/model/rep#1),
#      then #2, and so on. Collisions are resolved, never fatal.
#
# Absolute scoring means each candidate is judged alone, so presentation order
# carries no bias and needs no shuffling. §5's order-randomisation applies to the
# pairwise tiebreak only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_ROOT="${EVAL_ROOT:-$HERE}"
SPEC_NAME="${1:-${SPEC:-}}"
[ -n "$SPEC_NAME" ] || { echo "usage: $(basename "$0") <spec-name>   (or: export SPEC=pr-1234)" >&2; exit 1; }

RUNS="$EVAL_ROOT/runs/$SPEC_NAME"
ANON="$EVAL_ROOT/anon/$SPEC_NAME"
[ -d "$RUNS" ] || { echo "no runs for $SPEC_NAME" >&2; exit 1; }

MAPPING="$EVAL_ROOT/anon/$SPEC_NAME.mapping.json"
rm -rf "$ANON"; mkdir -p "$ANON"
PLAN="$ANON/.plan.tsv"

# Label assignment happens here, in one pass, before anything is copied — reuse and
# probing both need to see the whole set, which a per-run loop cannot.
python3 - "$RUNS" "$SPEC_NAME" "$MAPPING" "$PLAN" <<'ASSIGN'
import hashlib, json, os, sys

runs, spec, mapping_path, plan_path = sys.argv[1:5]

def label_for(model, rep, probe):
    key = f"{spec}/{model}/{rep}" + (f"#{probe}" if probe else "")
    digits = "".join(c for c in hashlib.sha256(key.encode()).hexdigest() if c.isdigit())
    return "candidate-" + digits[:2]

gate, skipped = [], 0
for model in sorted(os.listdir(runs)):
    mdir = os.path.join(runs, model)
    if not os.path.isdir(mdir):
        continue
    for rep in sorted(os.listdir(mdir)):
        run = os.path.join(mdir, rep)
        if not (rep.startswith("r") and os.path.isdir(run)):
            continue
        try:
            passed = json.load(open(os.path.join(run, "verify.json"))).get("pass") is True
        except Exception:
            passed = False
        (gate.append((model, rep, run)) if passed else None)
        skipped += 0 if passed else 1

prior, retired = {}, {}
try:
    old = json.load(open(mapping_path))
    for lab, v in (old.get("candidates") or {}).items():
        prior[(v["model"], v["rep"])] = lab
    for lab, v in (old.get("retired") or {}).items():
        prior.setdefault((v["model"], v["rep"]), lab)
        retired[lab] = v
except Exception:
    pass

taken = set(prior.values()) | set(retired)
assigned = {}
# Runs with a prior label keep it. Only then are new labels handed out, so a new run
# can never take a label a returning run is entitled to.
for model, rep, run in gate:
    if (model, rep) in prior:
        assigned[(model, rep)] = prior[(model, rep)]
for model, rep, run in gate:
    if (model, rep) in assigned:
        continue
    probe = 0
    while True:
        lab = label_for(model, rep, probe)
        if lab not in taken:
            break
        probe += 1
    if probe:
        print(f"  label {label_for(model, rep, 0)} taken — {model}/{rep} probed to {lab}",
              file=sys.stderr)
    assigned[(model, rep)] = lab
    taken.add(lab)

# Anything previously labelled that is not in this gate list retires: its label stays
# reserved so it can never come to mean a different run.
live = {(m, r) for m, r, _ in gate}
for (model, rep), lab in prior.items():
    if (model, rep) not in live:
        retired[lab] = {"model": model, "rep": rep}

with open(plan_path, "w") as f:
    for model, rep, run in gate:
        f.write(f"{assigned[(model, rep)]}\t{model}\t{rep}\t{run}\n")
with open(plan_path + ".retired", "w") as f:
    json.dump(retired, f)
print(skipped, file=open(plan_path + ".skipped", "w"))
ASSIGN

KEPT=0
SKIPPED="$(cat "$PLAN.skipped")"
: > "$ANON/.mapping.tmp"

while IFS=$'\t' read -r LABEL MODEL REP RUN; do
  [ -n "$LABEL" ] || continue
  DEST="$ANON/$LABEL"
  mkdir -p "$DEST"

  # Strip identity from the diff. Captured diffs carry no commit messages by
  # construction, so what's left is self-reference inside the code itself.
  # This cannot be complete (§5) — models have stylistic tells no filter removes.
  sed -E \
    -e '/Co-Authored-By:/d' \
    -e '/Generated with .*(Claude|GPT|Gemini|Grok|Copilot)/d' \
    -e 's/(Claude|Anthropic|OpenAI|ChatGPT|GPT-[0-9.]+|Gemini|Grok|GLM|Cursor)/[redacted]/g' \
    "$RUN/diff.patch" > "$DEST/diff.patch"

  cp "$RUN/verify.json" "$DEST/verify.json"
  printf '%s\t%s\t%s\n' "$LABEL" "$MODEL" "$REP" >> "$ANON/.mapping.tmp"
  KEPT=$((KEPT + 1))
done < "$PLAN"

# The judge never reads this file. Keep it out of anon/<spec>/candidate-*/ so it
# cannot be swept into a prompt by a careless glob.
# Written by python rather than awk so the retired block, which the reuse rule above
# depends on, cannot be corrupted by quoting.
python3 - "$SPEC_NAME" "$ANON/.mapping.tmp" "$PLAN.retired" "$MAPPING" <<'WRITE'
import json, sys
spec, tmp, retired_path, out = sys.argv[1:5]
cands = {}
for line in open(tmp):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 3:
        cands[parts[0]] = {"model": parts[1], "rep": parts[2]}
retired = json.load(open(retired_path))
# A label is live or retired, never both: a run that starts clearing the gate again
# reclaims its own label, and leaving the stale retired entry behind would suggest two
# runs share it.
for lab in list(retired):
    if lab in cands:
        del retired[lab]
doc = {"spec": spec, "candidates": dict(sorted(cands.items()))}
if retired:
    # Labels issued in an earlier sweep whose run no longer clears the gate. Kept so
    # they are never reissued, and so an old verdict can still be traced to its run.
    doc["retired"] = dict(sorted(retired.items()))
open(out, "w").write(json.dumps(doc, indent=2) + "\n")
WRITE
rm -f "$ANON/.mapping.tmp" "$PLAN" "$PLAN.retired" "$PLAN.skipped"

printf '%s\n  %s candidates blinded, %s skipped (Tier 0 fail or unverified)\n' \
  "$ANON" "$KEPT" "$SKIPPED"
printf '  mapping: %s\n' "$EVAL_ROOT/anon/$SPEC_NAME.mapping.json"
[ "$KEPT" -gt 0 ] || { echo "  nothing to judge" >&2; exit 1; }
