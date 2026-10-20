"""Replay WakePolicy (sweep_policy.py's rules) over the bench traces of each head
and print (1) a table at chosen operating points and (2) DET-style curves:
recall on each positive set against false accepts/h on dev-clean and AMI.

Usage: analyze.py <head> [<head>…] [--at thr:hits:strong ...]
Traces: $WAKE_WORK/traces/<head>-{recordings,inworld,devclean,ami}.txt, written by
bench_head.sh. --best adds the best operating point under three false-accept
budgets (tuned on the same sets it reports, so an upper bound)."""
import os, re, sys, pathlib

# The bench work directory: traces/<head>-<set>.txt, bench/inworld/…
HERE = pathlib.Path(os.environ.get("WAKE_WORK", pathlib.Path.home() / "moe-wake-v6work"))


def parse(path):
    files, neg_s, cur = [], 0.0, None
    if not path.exists():
        return None, 0.0
    for line in open(path, errors="replace"):
        m = re.match(r"  (hit |MISS|FALSE|ok   ) (\S+)", line)
        if m:
            cur = [m.group(2), m.group(1).strip() in ("hit", "MISS"), []]
            files.append(cur); continue
        if line.startswith("        ") and cur is not None:
            cur[2].extend((float(a), float(b)) for a, b in re.findall(r"(-?\d+\.\d+):(\d+\.\d+)", line))
        m = re.match(r"false accepts: \d+ in ([\d.]+) h", line)
        if m:
            neg_s += float(m.group(1)) * 3600
    return files, neg_s


def fires(trace, thr, hits, strong, refractory=2.0, within=0.25):
    run, last, fired_at, n = 0, None, None, 0
    for t, s in trace:
        if fired_at is not None and t - fired_at < refractory:
            continue
        if s < thr:
            run, last = 0, None; continue
        run = run + 1 if (last is not None and t - last <= within) else 1
        last = t
        if s >= strong or run >= hits:
            fired_at, run, last = t, 0, None; n += 1
    return n


def owner_heldout(names):
    """real_clips.py's split: positives sorted by prompt index, every third
    (n % 3 == 0) held out."""
    def idx(p):
        m = re.search(r"-(\d+)\.wav$", p); return int(m.group(1)) if m else 0
    ordered = sorted(sorted(names), key=idx)
    return {p for n, p in enumerate(ordered) if n % 3 == 0}


def load(head):
    sets = {}
    for s in ("recordings", "inworld", "devclean", "ami"):
        f, neg_s = parse(HERE / "traces" / f"{head}-{s}.txt")
        sets[s] = (f, neg_s)
    return sets


def measure(sets, thr, hits, strong):
    out = {}
    rec, _ = sets["recordings"]
    if rec:
        pos = [f for f in rec if f[1]]
        held = owner_heldout([f[0] for f in pos])
        out["owner held-out"] = (sum(1 for f in pos if f[0] in held and fires(f[2], thr, hits, strong)), len(held))
        out["owner all"] = (sum(1 for f in pos if fires(f[2], thr, hits, strong)), len(pos))
        negs = [f for f in rec if not f[1]]
        out["owner near-miss+room"] = (sum(1 for f in negs if fires(f[2], thr, hits, strong)), len(negs))
    iw, _ = sets["inworld"]
    if iw:
        # trace names carry no directory: split negatives by the speech folder listing
        pos = [f for f in iw if f[1]]
        negs = [f for f in iw if not f[1]]
        speech = {f[0] for f in negs if f[0].startswith("speech_")}
        out["inworld recall"] = (sum(1 for f in pos if fires(f[2], thr, hits, strong)), len(pos))
        con = [f for f in negs if f[0] not in speech]
        sp = [f for f in negs if f[0] in speech]
        out["inworld near-miss"] = (sum(1 for f in con if fires(f[2], thr, hits, strong)), len(con))
        out["inworld sentences"] = (sum(1 for f in sp if fires(f[2], thr, hits, strong)), len(sp))
    for s in ("devclean", "ami"):
        fs, neg_s = sets[s]
        if fs:
            n = sum(fires(f[2], thr, hits, strong) for f in fs if not f[1])
            out[f"{s} FA/h"] = (n, neg_s / 3600)
    return out


def fmt(k, v):
    a, b = v
    if k.endswith("FA/h"):
        return f"{a}/{b:.2f}h={a / b:.2f}" if b else "-"
    return f"{a}/{b} ({100 * a / b:.1f}%)" if b else "-"


def main():
    args = sys.argv[1:]
    ats = []
    if "--at" in args:
        i = args.index("--at"); ats = [a for a in args[i + 1:] if a != "--best"]; args = args[:i]
    args = [a for a in args if a != "--best"]
    heads = args
    data = {h: load(h) for h in heads}
    for h in heads:
        for at in ats:
            thr, hits, strong = at.split(":")
            m = measure(data[h], float(thr), int(hits), float(strong))
            print(f"{h} @{at}: " + " | ".join(f"{k} {fmt(k, v)}" for k, v in m.items()))
    print()
    # Curves: two policy families.
    if "--best" in sys.argv:
        best(heads, data)
        return
    fams = {"hits2": lambda t: (t, 2, 1.01), "hits2+strong.95": lambda t: (t, 2, max(t, 0.95)),
            "single": lambda t: (t, 1, t)}
    grid = [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.93, 0.95, 0.97, 0.98, 0.99]
    for fam, pol in fams.items():
        print(f"== {fam}")
        for h in heads:
            print(f"-- {h}")
            print(f"{'thr':>5} | {'own-held':>8} {'own-all':>8} {'iw-rec':>7} | {'own-nm':>6} {'iw-nm':>6} {'iw-sent':>7} | {'dev/h':>6} {'ami/h':>6}")
            for t in grid:
                m = measure(data[h], *pol(t))
                def pc(k):
                    v = m.get(k); return f"{100 * v[0] / v[1]:.1f}" if v and v[1] else "-"
                def rt(k):
                    v = m.get(k); return f"{v[0] / v[1]:.2f}" if v and v[1] else "-"
                def ct(k):
                    v = m.get(k); return f"{v[0]}/{v[1]}" if v else "-"
                print(f"{t:5.2f} | {pc('owner held-out'):>8} {pc('owner all'):>8} {pc('inworld recall'):>7} | "
                      f"{ct('owner near-miss+room'):>6} {pc('inworld near-miss'):>6} {pc('inworld sentences'):>7} | "
                      f"{rt('devclean FA/h'):>6} {rt('ami FA/h'):>6}")
        print()


def best(heads, data):
    """Best recall each head reaches while its false accepts stay at or under a
    budget, over thresholds 0.20-0.99 (0.01 steps) x hits 1-4 x strong
    {threshold, 0.95, off}. Tuned on the same sets it reports: an upper bound."""
    budgets = [("dev<=0.2 & ami<=0.25", 0.2, 0.25), ("dev<=0.5 & ami<=0.5", 0.5, 0.5), ("dev<=1 & ami<=1", 1.0, 1.0)]
    print("== best operating point per false-accept budget (ranked by owner-all recall, then Inworld recall)")
    for name, dmax, amax in budgets:
        for h in heads:
            top = None
            for t100 in range(20, 100):
                t = t100 / 100
                for hits in (1, 2, 3, 4):
                    for strong in sorted({t, max(t, 0.95), 1.01}):
                        m = measure(data[h], t, hits, strong)
                        d, a = m.get("devclean FA/h"), m.get("ami FA/h")
                        if not d or not a or d[0] / d[1] > dmax or a[0] / a[1] > amax:
                            continue
                        key = (m["owner all"][0], m["inworld recall"][0], -m["inworld near-miss"][0])
                        if top is None or key > top[0]:
                            top = (key, (t, hits, strong), m)
            if top:
                print(f"{name:22s} {h}: @{top[1]} " + " | ".join(f"{k} {fmt(k, v)}" for k, v in top[2].items()))
    print()


if __name__ == "__main__":
    main()
    if "--best" in sys.argv:
        pass
