"""Offline sweep of WakePolicy over `Alfie --wake-bench` traces (MOE_WAKE_TRACE=1).
Parses each file's per-stride scores, replays the policy (same rules as
Sources/MoeVoice/WakePolicy.swift) for a grid of threshold / hits / strong,
and prints recall over positives and false accepts per hour over the rest.
Usage: sweep_policy.py <trace file>… [--hours-negative H]  (H overrides the
negative audio duration when the trace's summary line is missing)."""
import re, sys

def parse(paths):
    files = []   # (name, is_positive, [(t, score)])
    neg_seconds = 0.0
    for path in paths:
        cur = None
        for line in open(path, errors="replace"):
            m = re.match(r"  (hit |MISS|FALSE|ok   ) (\S+)", line)
            if m:
                kind, name = m.group(1).strip(), m.group(2)
                cur = (name, kind in ("hit", "MISS"), [])
                files.append(cur)
                continue
            if line.startswith("        ") and cur is not None:
                cur[2].extend((float(a), float(b)) for a, b in re.findall(r"(\d+\.\d+):(\d+\.\d+)", line))
            m = re.match(r"false accepts: \d+ in ([\d.]+) h", line)
            if m: neg_seconds += float(m.group(1)) * 3600
    return files, neg_seconds

def fires(trace, threshold, hits, strong, refractory=2.0, within=0.25):
    run, last, fired_at, n = 0, None, None, 0
    for t, s in trace:
        if fired_at is not None and t - fired_at < refractory: continue
        if s < threshold: run, last = 0, None; continue
        run = run + 1 if (last is not None and t - last <= within) else 1
        last = t
        if s >= strong or run >= hits:
            fired_at, run, last = t, 0, None; n += 1
    return n

def main():
    hours_override = None
    argv = sys.argv[1:]
    if "--hours-negative" in argv:
        i = argv.index("--hours-negative")
        hours_override = float(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    args = argv
    files, neg_seconds = parse(args)
    hours = hours_override or (neg_seconds / 3600 if neg_seconds else None)
    pos = [f for f in files if f[1]]
    neg = [f for f in files if not f[1]]
    print(f"{len(pos)} positives, {len(neg)} negatives, {hours or 0:.2f} h negative audio")
    print(f"{'thr':>5} {'hits':>4} {'strong':>6} | {'recall':>7} | {'false':>5} {'FA/h':>7}")
    for thr in (0.5, 0.6, 0.7, 0.8, 0.9):
        for hits in (1, 2, 3, 4, 5):
            for strong in (0.95, 0.99, 1.01):
                r = sum(1 for f in pos if fires(f[2], thr, hits, strong) > 0)
                fa = sum(fires(f[2], thr, hits, strong) for f in neg)
                rate = fa / hours if hours else float("nan")
                print(f"{thr:5.2f} {hits:4d} {strong:6.2f} | {r:3d}/{len(pos):<3d} | {fa:5d} {rate:7.2f}")

main()
