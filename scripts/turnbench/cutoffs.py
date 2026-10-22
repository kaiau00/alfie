"""Did the person start talking again the moment Alfie took the turn?

The falsifier for the turn-taking work, and the only one that runs on the
owner's own voice rather than a corpus. `bench-turn-model.sh` measures the
model on LibriSpeech with a synthetic mid-phrase cut; this measures what
actually happened to him.

The signal: the gap between Alfie deciding the turn is over (`→ deciding`) and
the microphone opening on speech again (`→ capturing`). Someone who had
finished waits for the answer. Someone who was cut off carries straight on.

Two seconds is the line because Alfie's first token takes three to five, so
inside two seconds he is talking *before Alfie has said anything* — which is
continuing a sentence, not answering.

Measured 2026-09-05, before `TurnAudio.trimTrailingSilence` shipped:

    371 turns Alfie decided were over
    110 (30%) he was talking again within 2 s
    149 (40%) within 4 s

and the model's verdict on the ones he resumed within two seconds was
p=0.99 ×31, p=0.98 ×21, p=0.97 ×9, p=0.96 ×8 — near-certain "finished" on
the turns he plainly had not finished. **30% is the number to beat.**

Not a clean label: some of those two-second resumes are him answering
quickly, and a turn ended by the silence fallback rather than the model is
counted the same. It is a rate to move, not a truth to trust — which is why
the verdict histogram is printed beside it.
"""
import re, sys, datetime
from pathlib import Path

TS = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)Z\] (.*)$")
events = []
for line in Path(sys.argv[1]).read_text(errors="ignore").split("\n"):
    m = TS.match(line)
    if not m: continue
    when = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
    body = m.group(2)
    if "→ deciding(" in body:        events.append((when, "decided", body))
    elif "→ capturing(" in body:     events.append((when, "capture", body))
    elif "turn model: " in body:     events.append((when, "verdict", body))
    elif body.startswith("→ ") and not body.startswith("→ ("):
        events.append((when, "sent", body[2:]))

gaps, verdict_for = [], None
for i, (t, kind, body) in enumerate(events):
    if kind == "verdict": verdict_for = body
    if kind != "decided": continue
    for t2, k2, b2 in events[i+1:]:
        if k2 == "capture":
            g = (t2 - t).total_seconds()
            if g <= 60: gaps.append((g, verdict_for))
            break
        if k2 == "decided": break

gaps_only = sorted(g for g, _ in gaps)
n = len(gaps_only)
def pc(p): return gaps_only[int(n*p)] if n else 0
print(f"{n} turns Alfie decided were over\n")
print(f"  he was talking again within 2 s:  {sum(1 for g in gaps_only if g<=2):>4}  ({sum(1 for g in gaps_only if g<=2)/max(n,1):.0%})")
print(f"                     within 4 s:  {sum(1 for g in gaps_only if g<=4):>4}  ({sum(1 for g in gaps_only if g<=4)/max(n,1):.0%})")
print(f"\n  p10 {pc(.10):.0f}s   p50 {pc(.50):.0f}s   p90 {pc(.90):.0f}s")
fast = [v for g, v in gaps if g <= 2 and v]
print(f"\n  verdict on the turns he resumed within 2 s ({len(fast)} had one logged):")
import collections
for v, c in collections.Counter(re.search(r"p=([0-9.]+)", v).group(1) for v in fast if re.search(r"p=", v)).most_common(8):
    print(f"    p={v}  ×{c}")

# ---------------------------------------------------------------------------
# The other two ways a turn goes wrong, from the same log.
#
# dropped   Moe heard words and decided they were not for it. Measured
#           2026-09-05 before the speechTail fix: 82 of 200 (41%).
# level     `levelRatio` — the turn's loudness against the loudness the
#           session opened at — which should sit near 1.0 for the person who
#           opened it. Before the fix: p50 0.081, because it was measuring
#           the pause after they stopped rather than the speech. 202 of 345
#           fell under the scorer's 0.35 cliff and took its -1.5.

text = Path(sys.argv[1]).read_text(errors="ignore")
dropped = len(re.findall(r"→ dropped", text))
submitted = len(re.findall(r"→ submitted", text))
levels = [float(x) for x in re.findall(r"level ([0-9.]+)", text)]
print()
if dropped + submitted:
    print(f"  dropped as 'not for Alfie': {dropped}/{dropped+submitted}  ({dropped/(dropped+submitted):.0%})"
          f"   [was 41% on 2026-09-05]")
if levels:
    levels.sort()
    q = lambda p: levels[min(int(len(levels)*p), len(levels)-1)]
    under = sum(1 for x in levels if x < 0.35)
    print(f"  levelRatio: p10 {q(.1):.3f}  p50 {q(.5):.3f}  p90 {q(.9):.3f}"
          f"   (should centre near 1.0)")
    print(f"  under the scorer's 0.35 cliff: {under}/{len(levels)} ({under/len(levels):.0%})"
          f"   [was 59%]")
