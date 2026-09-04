#!/usr/bin/env python3
"""Estado de um sweep: o que passou, o que falhou, o que ainda esta rodando.

    usage: ./status.sh [spec-name]        (ou: export SPEC=pr-311)
           ./status.sh pr-311 --watch     repete a cada 30s

Le apenas artefatos ja gravados em runs/ — nao invoca modelo, nao roda suite, nao
escreve nada. Pode ser chamado no meio de um sweep com seguranca e quantas vezes quiser.

Como distinguir um run terminado de um travado, que e a pergunta que este script existe
para responder: um run que terminou tem metrics.json. Silencio no transcript de um run
que ja tem metrics.json e conclusao, nao travamento. Silencio num run SEM metrics.json e
que passa de STALL_S (1800s) e travamento, e a partir dessa versao do harness o proprio
runner o mata e grava termination_reason "stalled".
"""
import json, os, sys, time, glob, re

HERE = os.path.dirname(os.path.abspath(__file__))
EVAL_ROOT = os.environ.get("EVAL_ROOT", HERE)
STALL_S = int(os.environ.get("STALL_S", "1800"))

def kb(n):
    return "-" if n is None else (f"{n/1024:.0f} KB" if n >= 1024 else f"{n} B")

def read(p, default=None):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return default

def tests_line(run):
    """Resumo da suite, quando o gate rodou e reprovou."""
    for name in ("verify-regression.log", "verify.log"):
        p = os.path.join(run, name)
        if not os.path.exists(p):
            continue
        try:
            txt = open(p, errors="replace").read()
        except OSError:
            continue
        m = re.findall(r"^Tests:\s+(.+)$", txt, re.M)
        if m:
            return m[-1].strip()
    return None

def collect(spec):
    runs_dir = os.path.join(EVAL_ROOT, "runs", spec)
    if not os.path.isdir(runs_dir):
        sys.exit(f"sem runs em {runs_dir}")
    out = []
    for run in sorted(glob.glob(os.path.join(runs_dir, "*", "r*"))):
        if not os.path.isdir(run):
            continue
        model = os.path.basename(os.path.dirname(run))
        rep = os.path.basename(run)
        m = read(os.path.join(run, "metrics.json"))
        v = read(os.path.join(run, "verify.json"))
        tr = os.path.join(run, "transcript.jsonl")
        silence = int(time.time() - os.path.getmtime(tr)) if os.path.exists(tr) else None
        diff = os.path.join(run, "diff.patch")
        out.append(dict(
            model=model, rep=rep, run=run, m=m, v=v, silence=silence,
            diff=os.path.getsize(diff) if os.path.exists(diff) else None,
            transcript=os.path.getsize(tr) if os.path.exists(tr) else None,
        ))
    return out

def verdict(r):
    """Uma palavra sobre o run, e a razao quando nao passou."""
    if r["m"] is None:
        return "rodando", ""
    if r["v"] is None:
        return "sem gate", "verify.json ausente — Tier 0 nao rodou"
    if r["v"].get("pass"):
        return "PASS", ""
    why = r["v"].get("reason") or ""
    term = (r["m"] or {}).get("termination_reason")
    infra = (r["m"] or {}).get("infrastructure_error")
    if infra:
        return "FAIL", f"infra: {infra} — nao e resultado do modelo"
    if term == "stalled":
        t = tests_line(r["run"])
        return "FAIL", "travou; " + (f"suite: {t}" if t else "diff parcial")
    t = tests_line(r["run"])
    return "FAIL", why or (f"suite: {t}" if t else "gate reprovou")

def show(spec):
    rows = collect(spec)
    done = [r for r in rows if r["m"] is not None]
    live = [r for r in rows if r["m"] is None]
    print(f"\n{spec} — {len(rows)} runs ({len(done)} terminados, {len(live)} em andamento)"
          f"   {time.strftime('%H:%M:%S')}\n")

    hdr = f"{'run':<46} {'':<8} {'geracao':>8} {'steps':>6} {'diff':>7}  {'desfecho':<9} nota"
    print(hdr); print("-" * len(hdr))
    last = None
    for r in rows:
        if last and r["model"] != last:
            print()
        last = r["model"]
        st, note = verdict(r)
        m = r["m"] or {}
        steps = m.get("steps") if m.get("steps") is not None else m.get("turns")
        gen = m.get("generate_wall_clock_s")
        term = m.get("termination_reason") or ""
        if st == "rodando":
            sil = r["silence"]
            gen = f"~{sil}s" if sil is not None else "-"
            term = "ativo" if (sil is not None and sil < 120) else f"quieto {sil}s"
            note = ("normal" if (sil or 0) < STALL_S
                    else f"passou de STALL_S={STALL_S}s — o watchdog deve cortar")
            steps = None
        print(f"{r['model']}/{r['rep']:<8}"[:46].ljust(46)
              + f" {st:<8} {str(gen):>8} {str(steps or '-'):>6} {kb(r['diff']):>7}"
              + f"  {term:<9} {note}")

    print()
    for model in dict.fromkeys(r["model"] for r in rows):
        mr = [r for r in rows if r["model"] == model]
        fin = [r for r in mr if r["m"] is not None]
        ok = sum(1 for r in fin if (r["v"] or {}).get("pass"))
        infra = sum(1 for r in fin if (r["m"] or {}).get("infrastructure_error"))
        stall = sum(1 for r in fin if (r["m"] or {}).get("termination_reason") == "stalled")
        extra = []
        if stall: extra.append(f"{stall} travou")
        if infra: extra.append(f"{infra} erro de infra (nao conta como falha do modelo)")
        run = len(mr) - len(fin)
        if run: extra.append(f"{run} rodando")
        print(f"  {model:<44} Tier 0: {ok}/{len(fin)}"
              + (f"   ({', '.join(extra)})" if extra else ""))

    judgeable = sum(1 for r in rows if (r["v"] or {}).get("pass"))
    print(f"\n  {judgeable} runs passaram o Tier 0 e vao ao juiz.")
    if live:
        print("  Sweep ainda rodando — espere terminar antes de blind.sh / judge.py.")
    print()

args = [a for a in sys.argv[1:]]
watch = "--watch" in args
args = [a for a in args if a != "--watch"]
spec = args[0] if args else os.environ.get("SPEC")
if not spec:
    sys.exit("usage: status.sh <spec-name>   (ou: export SPEC=pr-311)")
while True:
    show(spec)
    if not watch:
        break
    time.sleep(30)
