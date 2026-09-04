#!/usr/bin/env python3
"""§11 reporting — joins the judged verdicts back to the models and aggregates.

    usage: ./report.py [spec-name] [--md] [--csv path]
           spec-name falls back to $SPEC when omitted

Reads   anon/<spec>.mapping.json          the blinding key (never seen by the judge)
        judged/<spec>/*.median.json       Tier 1 verdicts, per candidate
        runs/<spec>/*/r*/{metrics,verify}.json   Tier 0 and cost/time
Writes  stdout (or Markdown with --md, plus a per-run CSV with --csv)

Standard library only. Deanonymisation happens here and only here: everything
upstream of this script works on candidate labels.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

# Outcomes where the model ran but something outside it ended the run. It did the work,
# so these stay in the denominator — a route that stalls, trips a content filter or runs
# a suite past the gate cap is a real cost of using it — but they are counted out loud
# rather than blending into ordinary gate failures.
INTERRUPTED = {"stalled", "content-filter", "max-turns", "length"}

CRITERIA = [
    "spec_adherence",
    "behavioral_equivalence",
    "scope_discipline",
    "correctness_beyond_tests",
    "codebase_fit",
    "maintainability",
]


def tokens_from_transcript(run: Path) -> tuple[dict, bool | None]:
    """Read `usage` off the agent's result event, for runs whose metrics.json predates
    token extraction. Returns the same field names run-one.sh emits, plus the
    plausibility verdict: a diff needs roughly one token per four characters at an
    absolute floor, and a reported output below that means the usage covers only the
    final segment of a segmented run rather than the whole thing.
    """
    usage = {}
    try:
        for line in open(run / "transcript.jsonl"):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "result" and isinstance(ev.get("usage"), dict):
                usage = ev["usage"]
    except OSError:
        return {}, None
    if not usage:
        return {}, None
    tok = {
        "input": usage.get("inputTokens"),
        "output": usage.get("outputTokens"),
        "cache_read": usage.get("cacheReadTokens"),
        "cache_write": usage.get("cacheWriteTokens"),
    }
    plausible = None
    if isinstance(tok["output"], int):
        try:
            floor = len(open(run / "diff.patch").read()) // 4
        except OSError:
            floor = 0
        plausible = tok["output"] >= floor
    return tok, plausible


def parked(spec: str, root: Path) -> dict[tuple[str, str], list[dict]]:
    """Attempts moved out of runs/ and regenerated, read from stalled-runs/.

    They are ATTEMPTS, not repetitions. Each was replaced by a re-run of the same
    (model, rep), so folding them into pass@k would count one repetition twice and
    quietly depress every rate. What they do measure is how many tries a route needed
    to yield k=3 — the reliability cost of using it — and that is worth reporting
    precisely because moving a run out of runs/ otherwise erases it from the record.
    """
    out: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for m in sorted((root / "stalled-runs").glob("*/metrics.json")):
        try:
            j = json.loads(m.read_text())
        except Exception:
            continue
        if j.get("spec") and j["spec"] != spec:
            continue
        harness = j.get("harness", "cursor-agent")
        model = j.get("model", "?")
        # runs/ names an opencode model directory with slashes flattened; match it so
        # these rows line up with the aggregate keys.
        key = (harness, f"opencode__{model.replace('/', '_')}"
               if harness == "opencode" else model)
        out[key].append({
            "rep": j.get("rep"),
            "why": j.get("infrastructure_error") and "infra"
                   or j.get("termination_reason") or "?",
            "gen_s": j.get("generate_wall_clock_s"),
            "steps": j.get("steps"),
        })
    return out


def run_fields(run: Path) -> dict:
    """Everything read off one run directory: Tier 0 verdict plus cost.

    Both loops in load() go through here. They used to each build the dict themselves,
    and the second one — the sweep over runs/ that picks up whatever never reached the
    judge — was a reduced copy that drifted: no `prompt_tok`, no `output_tok`, no
    `verify_s`, no `ref_tests`, and `turns` without the `tool_calls` fallback the
    opencode harness needs. So a run that failed the gate contributed its wall clock to
    the cost table but not its turns or its tokens, and the table disagreed with itself.
    On pr-311 that put vtex-glm's turns median at 191,5 instead of 183 and reported
    `n tok` as 2/3 for a run whose tokens were sitting on disk.
    """
    r: dict = {}
    # The gate verdict and the reference-contract signal are kept apart: only the first
    # one gates, the second is information.
    try:
        vj = json.load(open(run / "verify.json"))
        r["gate"] = bool(vj.get("pass"))
        r["ref_tests"] = (vj.get("reference_tests") or {}).get("passed")
    except OSError:
        r["gate"] = None

    try:
        m = json.load(open(run / "metrics.json"))
    except OSError:
        m = {}
    r["harness"] = m.get("harness", "cursor-agent")
    r["gen_s"] = m.get("generate_wall_clock_s")
    r["verify_s"] = m.get("verify_wall_clock_s")
    # cursor-agent counts tool_call events as `turns`; opencode records `tool_calls`.
    r["turns"] = m.get("turns") or m.get("tool_calls")
    r["term"] = m.get("termination_reason")
    # Non-null means the model was never reached: an IAM denial, a TLS failure, a
    # dead gateway. Such a run measured the network, not the candidate.
    r["infra"] = m.get("infrastructure_error")

    tok = m.get("tokens") or {}
    plaus = m.get("tokens_plausible")
    # Runs generated before run-one.sh started extracting `usage` carry tokens: null,
    # so fall back to their transcript rather than reporting a blank column for data
    # that is sitting on disk.
    if not tok:
        tok, plaus = tokens_from_transcript(run)

    # inputTokens and cacheWriteTokens are the same quantity split differently by
    # different providers, so only their sum compares across models.
    r["prompt_tok"] = (tok.get("input") or 0) + (tok.get("cache_write") or 0) or None
    r["output_tok"] = tok.get("output")
    # False means the reported usage cannot account for the run's own diff, i.e. the run
    # was segmented, and such totals are excluded from the medians. Only run-one.sh
    # computes it — opencode runs carry None, so for those the column counts tokens
    # loaded rather than tokens checked.
    r["tok_ok"] = plaus

    # One normalised field for "the model worked and something external ended it".
    # gate_timed_out lives apart from termination_reason because it happens after
    # generation — the agent finished cleanly and the suite was the thing cut off.
    if m.get("gate_timed_out"):
        r["interrupt"] = "gate-timeout"
    else:
        r["interrupt"] = r["term"] if r["term"] in INTERRUPTED else None
    return r


def load(spec: str, root: Path) -> tuple[list[dict], dict]:
    mapping = json.load(open(root / "anon" / f"{spec}.mapping.json"))["candidates"]
    judged = root / "judged" / spec
    runs = root / "runs" / spec

    rows = []
    for label, who in mapping.items():
        model, rep = who["model"], who["rep"]
        run = runs / model / rep
        r: dict = {"candidate": label, "model": model, "rep": rep}

        # Tier 1
        med = judged / f"{label}.median.json"
        if med.exists():
            v = json.load(open(med))
            r["scores"] = {c: v["criteria"][c]["median"] for c in CRITERIA}
            r["spreads"] = {c: v["criteria"][c]["spread"] for c in CRITERIA}
            r["total"] = v["total_median"]
            r["max_spread"] = v["max_spread"]
            r["passes"] = v["passes"]

        r.update(run_fields(run))
        rows.append(r)

    # Every run, including those that never reached the judge — pass@k needs the
    # denominator, and a model whose runs all failed the gate must still appear.
    seen = {(r["model"], r["rep"]) for r in rows}
    for run in sorted(runs.glob("*/r*")):
        key = (run.parent.name, run.name)
        if key in seen or not (run / "metrics.json").exists():
            continue
        row = {"candidate": None, "model": key[0], "rep": key[1]}
        row.update(run_fields(run))
        rows.append(row)
    return rows, mapping


def med(vals):
    vals = [v for v in vals if v is not None]
    return st.median(vals) if vals else None


def fmt(v, width=0, dash="—"):
    if v is None:
        s = dash
    elif isinstance(v, float) and v.is_integer():
        # A median over an even count is a float; show 20.0 as 20, not "20".
        s = f"{int(v):,}".replace(",", ".")
    elif isinstance(v, float):
        s = f"{v:,.1f}".replace(",", "~").replace(".", ",").replace("~", ".")
    elif isinstance(v, int):
        s = f"{v:,}".replace(",", ".")
    else:
        s = str(v)
    return s.rjust(width) if width else s


def aggregate(rows: list[dict], park: dict | None = None) -> list[dict]:
    by = defaultdict(list)
    for r in rows:
        by[(r["harness"], r["model"])].append(r)

    out = []
    for (harness, model), rs in by.items():
        # k counts every run; measured drops the ones where the model was never
        # invoked. Reporting 0/3 for a model whose three runs were refused by IAM
        # attributes an infrastructure failure to the candidate, which is the single
        # most misleading thing this table can do.
        k = len(rs)
        measured = [r for r in rs if not r.get("infra")]
        rs = measured or rs
        gated = [r for r in measured if r.get("gate")]
        scored = [r for r in rs if r.get("total") is not None]
        # Token medians use only the runs whose reported usage is self-consistent.
        tok_ok = [r for r in rs if r.get("tok_ok") is not False]
        out.append({
            "harness": harness, "model": model, "k": k,
            "k_measured": len(measured),
            # The Tier 1 median is over judged runs, which is fewer than measured
            # whenever a run failed the gate. Showing k_measured there implied a
            # median over three when only two scores existed.
            "k_scored": len(scored),
            "unmeasured": k - len(measured),
            "unmeasured_why": next((r["infra"] for r in rs if r.get("infra")), None)
                              or next((r["infra"] for r in by[(harness, model)]
                                       if r.get("infra")), None),
            "discarded": (park or {}).get((harness, model), []),
            "interrupted": sum(1 for r in measured if r.get("interrupt")),
            "interrupted_why": sorted({r["interrupt"] for r in measured
                                       if r.get("interrupt")}),
            # pass@k: any measured run cleared the gate. pass^k: every measured one did.
            # Both over measured runs, never over k — see the note above.
            "pass_at_k": len(gated) > 0,
            "pass_pow_k": bool(measured) and len(gated) == len(measured),
            "gated": len(gated),
            "ref_tests_ok": sum(1 for r in rs if r.get("ref_tests")),
            "total_med": med([r["total"] for r in scored]),
            "total_all": sorted((r["total"] for r in scored), reverse=True),
            "max_spread": max((r.get("max_spread") or 0 for r in scored), default=None),
            "crit": {c: med([r["scores"][c] for r in scored]) for c in CRITERIA} if scored else {},
            "gen_med": med([r.get("gen_s") for r in rs]),
            "gen_all": sorted(r.get("gen_s") or 0 for r in rs),
            "turns_med": med([r.get("turns") for r in rs]),
            "prompt_med": med([r.get("prompt_tok") for r in tok_ok]),
            "output_med": med([r.get("output_tok") for r in tok_ok]),
            "tok_n": sum(1 for r in tok_ok if r.get("prompt_tok")),
        })
    # Ranked by rubric total; unscored models sort last rather than disappearing.
    return sorted(out, key=lambda a: (a["total_med"] is None, -(a["total_med"] or 0)))


def emit(agg: list[dict], rows: list[dict], md: bool) -> None:
    B, E = ("**", "**") if md else ("", "")
    P = (lambda *a: print(*a))
    # Sized to the data, not to a guess: opencode ids like
    # opencode__amazon-bedrock_anthropic.claude-sonnet-5 run to 49 characters and a
    # fixed 36 pushed every later column out of alignment.
    W = max([len(a["model"]) for a in agg] + [24]) + 2

    P(f"\n{B}Tier 1 — rubrica (mediana de {len(CRITERIA)} critérios, máximo 30){E}\n")
    hdr = ["modelo", "harness", "k", "total", "por rep", "spread"] + \
          [c.replace("_", " ")[:12] for c in CRITERIA]
    if md:
        P("| " + " | ".join(hdr) + " |")
        P("|" + "---|" * len(hdr))
    for a in agg:
        cells = [a["model"], a["harness"], str(a["k_scored"]), fmt(a["total_med"]),
                 " / ".join(str(int(x)) for x in a["total_all"]) or "—",
                 fmt(a["max_spread"])] + [fmt(a["crit"].get(c)) for c in CRITERIA]
        P(("| " + " | ".join(cells) + " |") if md else "  " + "  ".join(
            c.ljust(w) for c, w in zip(cells, [W, 13, 3, 6, 14, 7] + [12] * len(CRITERIA))))

    P(f"\n{B}Tier 0 — portão, e o contrato da referência{E}\n")
    hdr = ["modelo", "no portão", "pass@k", "pass^k", "ref-tests ok",
           "não medido", "interrompido", "tentativas"]
    if md:
        P("| " + " | ".join(hdr) + " |")
        P("|" + "---|" * len(hdr))
    for a in agg:
        # "no portão" is over measured runs. When some run never reached the model the
        # column says so, instead of quietly shrinking the denominator with no trace.
        gate_cell = f"{a['gated']}/{a['k_measured']}"
        # With nothing measured there is no verdict either way. "não" would read as
        # "this model failed", which is exactly the misattribution this table avoids.
        yes = (lambda b: "sim" if b else "não") if a["k_measured"] else (lambda b: "—")
        cells = [a["model"], gate_cell,
                 yes(a["pass_at_k"]),
                 yes(a["pass_pow_k"]),
                 f"{a['ref_tests_ok']}/{a['k_measured']}",
                 f"{a['unmeasured']}/{a['k']}" if a["unmeasured"] else "—",
                 (f"{a['interrupted']} ({', '.join(a['interrupted_why'])})"
                  if a["interrupted"] else "—"),
                 # Attempts spent, not repetitions obtained: 4 tries for 3 reps.
                 (f"{a['k'] + len(a['discarded'])} p/ {a['k']}"
                  if a["discarded"] else f"{a['k']}")]
        P(("| " + " | ".join(cells) + " |") if md else "  " + "  ".join(
            c.ljust(w) for c, w in zip(cells, [W, 10, 7, 7, 13, 11, 24, 11])))

    P(f"\n{B}Custo — tempo, turnos e tokens{E}\n")
    hdr = ["modelo", "tempo med", "por rep", "turns", "prompt tok", "output tok", "n tok"]
    if md:
        P("| " + " | ".join(hdr) + " |")
        P("|" + "---|" * len(hdr))
    for a in agg:
        cells = [a["model"], fmt(a["gen_med"]),
                 " / ".join(str(x) for x in a["gen_all"]),
                 fmt(a["turns_med"]), fmt(a["prompt_med"]), fmt(a["output_med"]),
                 f"{a['tok_n']}/{a['k']}"]
        P(("| " + " | ".join(cells) + " |") if md else "  " + "  ".join(
            c.ljust(w) for c, w in zip(cells, [W, 10, 18, 6, 12, 11, 6])))

    # Facts a reader needs in order not to misread the tables above.
    P("")
    harnesses = {a["harness"] for a in agg}
    if len(harnesses) > 1:
        P(f"{B}Populações separadas por harness.{E} Linhas com harness diferente não são")
        P("comparáveis entre si: mudam o harness, o gateway e o deployment do modelo ao")
        P("mesmo tempo, e o eval não isola nenhum dos três.")
    un = [a for a in agg if a["unmeasured"]]
    if un:
        P(f"{B}Runs não medidos, fora do denominador:{E}")
        for a in un:
            why = (a["unmeasured_why"] or "").strip().replace("\n", " ")
            if len(why) > 150:
                why = why[:147] + "..."
            P(f"  {a['model']} — {a['unmeasured']} de {a['k']}: {why}")
        P("  O modelo não foi invocado nesses runs. Contá-los como reprovação atribuiria")
        P("  ao candidato uma falha de infraestrutura; ficam de fora da taxa, não como 0.")
    disc = [a for a in agg if a["discarded"]]
    if disc:
        P(f"{B}Tentativas descartadas e regeradas:{E}")
        for a in disc:
            det = ", ".join(f"r{d['rep']} {d['why']} ({d['gen_s']}s, "
                            f"{d['steps'] if d['steps'] is not None else '—'} steps)"
                            for d in sorted(a["discarded"], key=lambda x: x["rep"] or 0))
            P(f"  {a['model']} — {len(a['discarded'])}: {det}")
        P("  São tentativas, não repetições: cada uma foi substituída por um novo run da")
        P("  mesma repetição, então entram como custo de confiabilidade da rota e ficam")
        P("  fora do pass@k, onde contariam a mesma repetição duas vezes.")
    inter = [a for a in agg if a["interrupted"]]
    if inter:
        P(f"{B}Runs interrompidos, dentro do denominador:{E} " +
          ", ".join(f"{a['model']} ({a['interrupted']}× {'/'.join(a['interrupted_why'])})"
                    for a in inter))
        P("  Aqui o modelo trabalhou e algo externo encerrou o run. Contam como não-passe,")
        P("  porque a taxa de interrupção é um custo real da rota, e vêm nomeados para que")
        P("  ninguém os leia como código errado.")
    thin = [a for a in agg if a["k_measured"] < 3]
    if thin:
        P(f"{B}Amostra reduzida:{E} " +
          ", ".join(f"{a['model']} (k={a['k_measured']})" for a in thin) +
          " — sem k=3 não há distribuição, só um ponto.")
    part = [a for a in agg if a["tok_n"] < a["k"]]
    if part:
        P(f"{B}Tokens parciais:{E} " + ", ".join(f"{a['model']} ({a['tok_n']}/{a['k']})" for a in part) +
          " — medianas de token usam só os runs cujo consumo reportado é autoconsistente.")
    if any(a["harness"] == "opencode" for a in agg):
        P(f"{B}`n tok` não significa o mesmo nas duas populações.{E} A checagem de")
        P("plausibilidade — o output reportado dá conta do próprio diff? — é feita só pelo")
        P("`run-one.sh`. Nas linhas do `opencode` a coluna conta tokens *carregados*, não")
        P("*verificados*, e por isso tende a marcar k/k mesmo onde a mesma checagem")
        P("reprovaria.")
    P("Custo por solução aprovada não é calculável: nenhum dos harnesses reporta preço.")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("spec", nargs="?", default=os.environ.get("SPEC"))
    ap.add_argument("--md", action="store_true", help="tabelas em Markdown")
    ap.add_argument("--csv", help="também grava uma linha por run")
    args = ap.parse_args()
    if not args.spec:
        ap.error("no spec given and $SPEC is unset")

    root = Path(os.environ.get("EVAL_ROOT", Path(__file__).parent)).resolve()
    try:
        rows, mapping = load(args.spec, root)
    except FileNotFoundError as exc:
        print(f"{exc} — run blind.sh and judge.py first", file=sys.stderr)
        return 1

    agg = aggregate(rows, parked(args.spec, root))
    print(f"{args.spec}: {len(rows)} runs, {sum(1 for r in rows if r.get('total') is not None)} julgados")
    emit(agg, rows, args.md)

    if args.csv:
        cols = ["model", "rep", "harness", "candidate", "gate", "ref_tests", "total",
                "max_spread", "gen_s", "verify_s", "turns", "prompt_tok", "output_tok", "tok_ok"]
        with open(args.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            for r in sorted(rows, key=lambda r: (r["model"], r["rep"])):
                w.writerow(r)
        print(f"\ncsv: {args.csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
