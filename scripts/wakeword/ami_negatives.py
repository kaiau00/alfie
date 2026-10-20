"""AMI meeting audio (CC-BY 4.0) as conversational negatives: the Mix-Headset
16 kHz mono recordings of the ES20xx scenario meetings, never the dev/test
meetings (ES2011, ES2004 — ES2004 is the Mac-side conversational FA bench).
Cut into 15 s chunks (the augmenter reads a whole background file per clip,
so 20-minute files would make every clip read 40 MB), silent chunks dropped.
They land in data/ami, which hey-moe.yaml lists under background_paths: so
they are both the background negative class's crops and babble mixed under
every class. Usage: ami_negatives.py"""
import pathlib, subprocess, sys
import numpy as np
import soundfile as sf

W = pathlib.Path("/data/wake")
RAW = W / "ami-raw"
OUT = W / "train/data/ami"
URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{m}/audio/{m}.Mix-Headset.wav"
MEETINGS = [f"ES20{n:02d}{s}" for n in (2, 3, 5, 6, 7, 8, 9, 10, 12, 13, 14, 15, 16) for s in "abcd"]
SR, CHUNK = 16000, 15

RAW.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)
got, seconds, chunks = 0, 0.0, 0
for m in MEETINGS:
    raw = RAW / f"{m}.wav"
    if not raw.exists():
        r = subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(raw) + ".part", URL.format(m=m)])
        if r.returncode != 0:
            print(f"{m}: download failed ({r.returncode})"); continue
        pathlib.Path(str(raw) + ".part").rename(raw)
    a, sr = sf.read(raw, dtype="float32")
    if a.ndim > 1:
        a = a.mean(axis=1)
    if sr != SR:
        print(f"{m}: {sr} Hz, skipped"); continue
    got += 1; seconds += len(a) / SR
    step = CHUNK * SR
    for i in range(0, len(a) - step + 1, step):
        c = a[i:i + step]
        if 20 * np.log10(np.sqrt(np.mean(c * c)) + 1e-9) < -50:
            continue
        sf.write(OUT / f"{m}_{i // step:04d}.wav", c, SR, subtype="PCM_16")
        chunks += 1
print(f"AMI: {got}/{len(MEETINGS)} meetings, {seconds / 3600:.1f} h, {chunks} chunks")
sys.exit(0 if got >= 30 else 1)
