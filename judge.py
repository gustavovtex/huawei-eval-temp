#!/usr/bin/env python3
"""Tier 1 judging — §7. Opus 5 scores each blinded candidate against the reference.

Runs through `cursor-agent`, same binary as generation, so there is one tool and
one credential for the whole eval. Standard library only — no pip install.

    usage: ./judge.py [spec-name] [--passes 3] [--jobs 4] [--candidate candidate-A7]
           spec-name falls back to $SPEC when omitted

Reads   anon/<spec>/candidate-*/{diff.patch,verify.json}   (built by blind.sh)
Writes  judged/<spec>/<candidate>.<pass>.json              (one file per pass)
        judged/<spec>/<candidate>.median.json              (median + spread)

Separate tree from runs/ on purpose: a revised rubric can be re-judged without
re-paying for generation (§9).

WHAT THIS ROUTE GIVES UP vs. calling the API directly, all of it deliberate:

  * No server-side schema enforcement. `--output-format json` is a transport
    format, not a guarantee. Replaced by client-side validation plus retry below.
  * No `cache_control`. The stable prefix (rubric + spec + reference) cannot be
    pinned, so it is re-sent on every pass. Cursor may cache internally; there is
    no way to control or observe it from here.
  * No `fallbacks` and no `stop_reason`, so a refusal looks like a malformed
    answer rather than a labelled outcome.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

MODEL = "claude-opus-5-thinking-high"   # §7: high, thinking on
TIMEOUT_S = 1800                         # high judging runs for minutes
# argv ceiling is ARG_MAX (1 MiB on macOS) minus environment and the rest of the
# command line. Past this the inputs go to files in the workspace instead.
INLINE_LIMIT = 600_000

CRITERIA = [
    "spec_adherence",
    "behavioral_equivalence",
    "scope_discipline",
    "correctness_beyond_tests",
    "codebase_fit",
    "maintainability",
]

SCHEMA_DOC = """{
  "criteria": {
    "<each of the six criterion names>": {
      "score": <integer 1-5>,
      "deductions": [
        { "diff": "candidate" | "reference",
          "file": "<path>", "line": <integer>, "reason": "<one line>" }
      ]
    }
  },
  "summary": "<one or two sentences>"
}"""

INSTRUCTIONS = f"""\
You are scoring ONE candidate implementation of a spec against the reference \
implementation that actually shipped and runs in production, using the rubric.

The reference is the anchor and it scores 4 — not 5. A candidate that is \
genuinely better than the reference on a criterion scores 5.

Deduct for different *behavior*. Never deduct for a different *approach*: a \
candidate reaching the same observable outcome by another route is correct, \
whatever its file layout, decomposition, or naming.

Every deduction carries a file:line citation and states which diff it points at. \
Do not record a deduction you cannot cite.

Score each criterion independently. Do not average anything yourself.

Reply with a single JSON object and nothing else — no prose before or after, no \
markdown fences. Exactly these six criterion keys: {", ".join(CRITERIA)}.

Shape:
{SCHEMA_DOC}"""


# --- validation ---------------------------------------------------------------
# Hand-rolled so the script stays stdlib-only. Enforces exactly what the schema
# would have enforced server-side, and its error strings are fed back to the
# model on retry.
def validate(v: object) -> list[str]:
    errs: list[str] = []
    if not isinstance(v, dict):
        return [f"top level must be an object, got {type(v).__name__}"]
    if not isinstance(v.get("summary"), str):
        errs.append("missing string 'summary'")
    crit = v.get("criteria")
    if not isinstance(crit, dict):
        return errs + ["missing object 'criteria'"]
    for extra in sorted(set(crit) - set(CRITERIA)):
        errs.append(f"unexpected criterion {extra!r}")
    for name in CRITERIA:
        c = crit.get(name)
        if not isinstance(c, dict):
            errs.append(f"criteria.{name}: missing")
            continue
        if c.get("score") not in (1, 2, 3, 4, 5):
            errs.append(f"criteria.{name}.score must be an integer 1-5, got {c.get('score')!r}")
        ded = c.get("deductions")
        if not isinstance(ded, list):
            errs.append(f"criteria.{name}.deductions must be an array")
            continue
        for i, d in enumerate(ded):
            at = f"criteria.{name}.deductions[{i}]"
            if not isinstance(d, dict):
                errs.append(f"{at}: must be an object")
                continue
            if d.get("diff") not in ("candidate", "reference"):
                errs.append(f"{at}.diff must be 'candidate' or 'reference'")
            for k, t in (("file", str), ("line", int), ("reason", str)):
                if not isinstance(d.get(k), t):
                    errs.append(f"{at}.{k} must be {t.__name__}")
    return errs


def extract_json(stdout: str) -> object:
    """Pull the verdict out of whatever cursor-agent hands back.

    The exact shape of `--output-format json` is not documented, so try the
    plausible envelope keys, then fall back to treating stdout as the text
    itself. Confirm the real key on the first run and simplify this.
    """
    text = stdout
    try:
        env = json.loads(stdout)
    except json.JSONDecodeError:
        pass
    else:
        if isinstance(env, dict):
            for key in ("result", "response", "text", "content", "message", "output"):
                if isinstance(env.get(key), str):
                    text = env[key]
                    break
            else:
                # Already the verdict, not an envelope.
                if "criteria" in env:
                    return env
        elif isinstance(env, list):
            text = "\n".join(str(x) for x in env)

    text = re.sub(r"^\s*```(?:json)?\s*|\s*```\s*$", "", text.strip())
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise ValueError("no JSON object in output")
    return json.loads(text[start:end + 1])


# --- one judging call ---------------------------------------------------------
def judge_once(agent: str, spec_dir: Path, candidate: Path, model: str,
               correction: str = "") -> tuple[dict, str]:
    rubric = (spec_dir.parent.parent / "rubric.md").read_text()
    spec = (spec_dir / "SPEC.md").read_text()
    reference = (spec_dir / "reference-impl.patch").read_text()
    cand_diff = (candidate / "diff.patch").read_text()
    verify = (candidate / "verify.json").read_text()

    sections = [
        ("RUBRIC", rubric),
        ("SPEC — the task the candidate was given", spec),
        ("REFERENCE IMPLEMENTATION (shipped, in production)", reference),
        ("CANDIDATE IMPLEMENTATION", cand_diff),
        ("TIER 0 RESULTS FOR THIS CANDIDATE", verify),
    ]
    body = "\n\n".join(f"=== {h} ===\n{t}" for h, t in sections)
    prompt = f"{body}\n\n=== TASK ===\n{INSTRUCTIONS}"
    if correction:
        prompt += f"\n\nYour previous reply was rejected:\n{correction}\nReturn corrected JSON only."

    # The workspace is a throwaway directory holding nothing but these inputs,
    # under neutral filenames. This is what keeps §5 blinding intact: cursor-agent
    # is an agent with file access, and pointed anywhere near the eval tree it
    # could read anon/<spec>.mapping.json or the model names in runs/ paths and
    # deanonymise the candidates. --sandbox enabled and --mode ask keep it read-
    # only on top of that.
    ws = Path(tempfile.mkdtemp(prefix="judge-"))
    try:
        if len(prompt.encode()) > INLINE_LIMIT:
            for name, text in (("RUBRIC.md", rubric), ("SPEC.md", spec),
                               ("reference.patch", reference),
                               ("candidate.patch", cand_diff),
                               ("tier0.json", verify)):
                (ws / name).write_text(text)
            prompt = (
                "Read RUBRIC.md, SPEC.md, reference.patch, candidate.patch and "
                f"tier0.json in this directory, then:\n\n{INSTRUCTIONS}"
            )
            if correction:
                prompt += f"\n\nYour previous reply was rejected:\n{correction}"

        cmd = [agent, "-p", "--model", model, "--output-format", "json",
               "--workspace", str(ws), "--mode", "ask", "--sandbox", "enabled",
               "--trust", prompt]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S, cwd=ws)
    finally:
        shutil.rmtree(ws, ignore_errors=True)

    if proc.returncode != 0:
        raise RuntimeError(f"cursor-agent exited {proc.returncode}: {proc.stderr.strip()[:400]}")

    verdict = extract_json(proc.stdout)
    errs = validate(verdict)
    if errs:
        raise ValueError("; ".join(errs[:6]))
    return verdict, proc.stdout


def main() -> int:
    ap = argparse.ArgumentParser()
    # Positional wins; $SPEC is the fallback so the name is typed once per session.
    ap.add_argument("spec", nargs="?", default=os.environ.get("SPEC"))
    ap.add_argument("--passes", type=int, default=3)
    ap.add_argument("--candidate", help="judge only this one")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--retries", type=int, default=2, help="per pass, on invalid JSON")
    ap.add_argument("--jobs", type=int, default=4,
                    help="candidates judged concurrently; safe to raise, see note below")
    args = ap.parse_args()
    if not args.spec:
        ap.error("no spec given and $SPEC is unset")

    agent = shutil.which("cursor-agent") or "/Users/gustavo.oliveira/.local/bin/cursor-agent"
    if not os.access(agent, os.X_OK):
        print("cursor-agent not found on PATH", file=sys.stderr)
        return 1

    eval_root = Path(os.environ.get("EVAL_ROOT", Path(__file__).parent)).resolve()
    spec_dir = eval_root / "specs" / args.spec
    anon = eval_root / "anon" / args.spec
    out = eval_root / "judged" / args.spec
    out.mkdir(parents=True, exist_ok=True)

    candidates = sorted(
        d for d in anon.glob("candidate-*")
        if d.is_dir() and (args.candidate is None or d.name == args.candidate)
    )
    if not candidates:
        print(f"no blinded candidates in {anon} — run blind.sh first", file=sys.stderr)
        return 1

    version = subprocess.run([agent, "--version"], capture_output=True, text=True
                             ).stdout.strip().splitlines()[:1]
    print(f"judge: {args.model} via cursor-agent {version[0] if version else '?'}\n")

    def score_candidate(cand: Path) -> tuple[Path, list[dict]]:
        verdicts = []
        for p in range(args.passes):
            correction = ""
            for attempt in range(args.retries + 1):
                try:
                    v, raw = judge_once(agent, spec_dir, cand, args.model, correction)
                except (ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
                    correction = str(exc)[:600]
                    print(f"  {cand.name} pass {p} attempt {attempt}: {correction[:160]}",
                          file=sys.stderr)
                    continue
                v["_meta"] = {"model": args.model, "pass": p, "attempts": attempt + 1}
                (out / f"{cand.name}.{p}.json").write_text(json.dumps(v, indent=2))
                verdicts.append(v)
                break
        return cand, verdicts

    # Judging is the one phase where concurrency costs nothing. It touches no git
    # repository and no test suite, each call already gets its own mkdtemp
    # workspace, and its duration is not a reported metric for any model — unlike
    # generation, where concurrent runs would contend for CPU and destroy the
    # per-run wall clock the report depends on.
    scored = 0
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = pool.map(score_candidate, candidates)

    for cand, verdicts in results:
        if not verdicts:
            print(f"  {cand.name}: no usable passes", file=sys.stderr)
            continue

        # Median per criterion, never a mean — and keep the spread. A criterion
        # where the passes disagree is a criterion that needs rewriting, and that
        # signal is lost if only the aggregate is stored (§7).
        merged = {"candidate": cand.name, "passes": len(verdicts),
                  "model": args.model, "criteria": {}}
        for c in CRITERIA:
            scores = [v["criteria"][c]["score"] for v in verdicts]
            merged["criteria"][c] = {
                "median": statistics.median(scores),
                "scores": scores,
                "spread": max(scores) - min(scores),
            }
        merged["total_median"] = sum(m["median"] for m in merged["criteria"].values())
        merged["max_spread"] = max(m["spread"] for m in merged["criteria"].values())
        (out / f"{cand.name}.median.json").write_text(json.dumps(merged, indent=2))
        scored += 1

        flag = "   <-- passes disagree, rubric suspect" if merged["max_spread"] >= 2 else ""
        print(f"  {cand.name}  total={merged['total_median']:>5}  "
              f"spread={merged['max_spread']}  passes={len(verdicts)}/{args.passes}{flag}")

    print(f"\n{out}")
    return 0 if scored else 1


if __name__ == "__main__":
    sys.exit(main())
