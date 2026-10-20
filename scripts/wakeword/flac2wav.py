"""LibriSpeech FLAC → 16 kHz mono WAV, for the trainer's background path
(it collects .wav only). Usage: flac2wav.py <src root> <dst dir>"""
import sys, pathlib, soundfile as sf
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
n = 0
for f in sorted(src.rglob("*.flac")):
    audio, sr = sf.read(f, dtype="int16")
    assert sr == 16000, (f, sr)
    sf.write(dst / (f.stem + ".wav"), audio, 16000, subtype="PCM_16")
    n += 1
print("converted", n)
