"""Turn the stamp file into a table.

**A run that goes wrong has to show up as a run that went wrong.** The first
version silently dropped any run with a missing stamp and never looked at the
exit code, so a wedged turn — the exact thing a cold-start measurement is
supposed to notice — vanished from the sample and made the median *better*.
Now an incomplete or failed run is counted, named, and kept out of the
statistics with a line saying so.
"""
import statistics
import sys

runs = {}
order = []
for line in open(sys.argv[1]):
    parts = line.split()
    if not parts:
        continue
    if parts[0] == "SPAWN":
        runs[parts[2]] = {"t0": float(parts[1])}
        order.append(parts[2])
    elif parts[0] == "DONE":
        runs[parts[2]]["t2"] = float(parts[1])
        for field in parts[3:]:
            if field.startswith("rc="):
                runs[parts[2]]["rc"] = int(field[3:])
    else:
        if not order:
            continue
        r = runs[order[-1]]
        t = float(parts[0])
        if "chat/completions" in parts[2]:
            r.setdefault("tchat", t)
        else:
            r.setdefault("tprobe", t)

to_model, to_reply, to_probe = [], [], []
bad = []

print("run    spawn->first probe   spawn->model call   spawn->reply   rc")
for name in order:
    r = runs[name]
    rc = r.get("rc")
    elapsed = (r["t2"] - r["t0"]) if "t2" in r else None
    if rc not in (0, None) or "tchat" not in r or "t2" not in r:
        why = []
        if rc not in (0, None):
            why.append("exit %d" % rc)
        if "tchat" not in r:
            why.append("never called the model")
        if "t2" not in r:
            why.append("never finished")
        bad.append((name, ", ".join(why), elapsed))
        print("%-6s %s%s" % (name, "FAILED — " + ", ".join(why),
                             "" if elapsed is None else " after %.3f s" % elapsed))
        continue
    p = r.get("tprobe", r["tchat"]) - r["t0"]
    m = r["tchat"] - r["t0"]
    d = r["t2"] - r["t0"]
    to_probe.append(p)
    to_model.append(m)
    to_reply.append(d)
    print("%-6s %14.3f s %17.3f s %14.3f s   %s"
          % (name, p, m, d, "0" if rc is None else rc))


def stat(name, xs):
    if not xs:
        print("%-22s no successful runs" % name)
        return
    print("%-22s n=%d  min %.3f  median %.3f  max %.3f" %
          (name, len(xs), min(xs), statistics.median(xs), max(xs)))


print()
stat("spawn -> first probe", to_probe)
stat("spawn -> model call", to_model)
stat("spawn -> reply", to_reply)
if bad:
    print()
    print("%d of %d runs did not complete and are NOT in the numbers above:"
          % (len(bad), len(order)))
    for name, why, elapsed in bad:
        print("  %s: %s%s" % (name, why,
                              "" if elapsed is None else " (%.3f s)" % elapsed))
    sys.exit(1)
