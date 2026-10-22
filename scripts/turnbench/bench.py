"""How often does the turn model take the turn while somebody is still talking?

Two errors, and they are not the same thing to the person:

  cut off   the model says finished while they are mid-sentence. They have
            to say it again, and it feels like being interrupted.
  dawdled   the model says mid-thought when they had finished. Costs a wait;
            the silence fallback ends the turn anyway.

Ground truth comes from the audio, not from the model: a whole clip is a
speaker finishing, the same clip cut at 55% is a speaker still going. The
variable is how much silence follows — because Alfie cannot ask until the VAD
reports a stop, and the VAD will not report one until it has heard
`minSilenceDuration` of quiet.
"""
import argparse, glob, sys
from pathlib import Path
import numpy as np, soundfile as sf, onnxruntime as ort

sys.path.insert(0, str(Path(__file__).parent))
from whisper_mel import features, left_pad, SR, N

ap = argparse.ArgumentParser()
ap.add_argument("--model", default=str(Path.home() / ".moe/models/smart-turn/smart-turn-v3.2-cpu.onnx"))
ap.add_argument("--clips", required=True, help="glob of 16 kHz wavs, ≥2 s each")
ap.add_argument("--n", type=int, default=80)
ap.add_argument("--residuals", default="0.00,0.05,0.10,0.25")
ap.add_argument("--thresholds", default="0.3,0.4,0.5,0.6,0.7,0.8")
a = ap.parse_args()

sess = ort.InferenceSession(a.model); name = sess.get_inputs()[0].name
def p(x): return float(sess.run(None, {name: features(left_pad(x))})[0].ravel()[0])

RESID = [float(x) for x in a.residuals.split(",")]
full = {q: [] for q in RESID}; cut = {q: [] for q in RESID}
for f in sorted(glob.glob(a.clips))[: a.n]:
    y, sr = sf.read(f, dtype="float32")
    if y.ndim > 1: y = y[:, 0]
    if sr != SR or len(y) < SR * 2: continue
    y = y[-(N - SR * 2):]
    c = y[: int(len(y) * 0.55)]
    for q in RESID:
        pad = np.zeros(int(SR * q), dtype=np.float32)
        full[q].append(p(np.concatenate([y, pad])))
        cut[q].append(p(np.concatenate([c, pad])))

n = len(full[RESID[0]])
if not n:
    sys.exit("no usable clips — need 16 kHz mono wavs of at least 2 s")
print(f"{n} clips\n")
print(f"{'silence left on':>16}{'threshold':>11}{'cut off mid-sentence':>22}{'dawdled':>10}{'both':>8}")
best = None
for q in RESID:
    fu, cu = np.array(full[q]), np.array(cut[q])
    for t in [float(x) for x in a.thresholds.split(",")]:
        wrong, late = (cu > t).mean(), (fu <= t).mean()
        if best is None or wrong + late < best[0]: best = (wrong + late, q, t)
        print(f"{q:>14.2f} s{t:>11.2f}{wrong:>21.0%}{late:>10.0%}{wrong+late:>8.2f}")
    print()
print(f"best combined:   silence {best[1]:.2f} s, threshold {best[2]:.2f}")
print(f"Alfie ships:       silence 0.00 s (TurnAudio.trimTrailingSilence),")
print(f"                 threshold {0.3:.2f} (SmartTurnDetector.threshold)")
