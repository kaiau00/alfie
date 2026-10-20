#!/bin/bash
# AMI test-set meetings (never trained on: the Fly run uses ES2002-ES2016
# minus ES2004/ES2011) as a conversational false-accept bench, cut into
# 10-minute files so a killed bench loses little.
set -u
cd "${WAKE_WORK:-$HOME/moe-wake-v6work}/bench"
mkdir -p ami-raw ami
for m in ES2004a ES2004b ES2004c ES2004d IS1009a IS1009b IS1009c IS1009d; do
  [ -f "ami-raw/$m.wav" ] || curl -fsSL --cacert ../ca-bundle.pem -o "ami-raw/$m.wav" \
    "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/$m/audio/$m.Mix-Headset.wav" || echo "$m failed"
done
../venv/bin/python - <<'PY'
import glob, os, soundfile as sf
tot = 0
for f in sorted(glob.glob("ami-raw/*.wav")):
    a, sr = sf.read(f, dtype="float32")
    assert sr == 16000
    step = 600 * sr
    for i in range(0, len(a), step):
        sf.write(f"ami/{os.path.basename(f)[:-4]}_{i // step:02d}.wav", a[i:i + step], sr, subtype="PCM_16")
    tot += len(a) / sr
print(f"AMI bench: {tot / 3600:.2f} h")
PY
