"""Reference scores for LiveKit's own fixture (hey_livekit.onnx +
positive/negative.wav) through the reference runtime, to check the Swift
port. Also scores a few shifted windows so the comparison covers more than
one input."""
import json, sys, wave
import numpy as np
from livekit.wakeword import WakeWordModel

here = "/path/to/wake/"

def load(path):
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    return pcm

model = WakeWordModel(models=[here + "hey_livekit.onnx"])
out = {}
for name in ("positive", "negative"):
    pcm = load(here + name + ".wav")
    cases = {"full": pcm}
    # Shifted: the phrase earlier in the window (zeros appended).
    cases["shift1280"] = np.concatenate([pcm[1280:], np.zeros(1280, np.int16)])
    cases["shift6400"] = np.concatenate([pcm[6400:], np.zeros(6400, np.int16)])
    for k, a in cases.items():
        s = model.predict(a)["hey_livekit"]
        out[f"{name}/{k}"] = float(s)
        # Save the exact float input the Swift side should use.
        (a.astype(np.float32) / 32768.0).tofile(here + f"{name}_{k}.f32")
print(json.dumps(out, indent=1))
json.dump(out, open(here + "ref_scores.json", "w"), indent=1)
