"""Codec round-trip on a random 30% of the ORIGINAL clips in every split,
positives and negatives alike (research-wakeword.md §2: a real-vs-TTS
classifier separates the two at 98% from codec traces alone, so the codec
must not be a class feature). MP3 32–128 kbps or Opus 12–32 kbps, decoded
back to 16 kHz mono PCM at the original length, in place. Runs before
augment; parallel over all cores. Idempotent: a marker per split.
Usage: codec_pass.py"""
import multiprocessing as mp, os, pathlib, random, re, subprocess, tempfile
import numpy as np
import soundfile as sf

OUT = pathlib.Path("/data/wake/train/output/hey_moe")
SPLITS = ["positive_train", "positive_test", "negative_train", "negative_test",
          "background_train", "background_test"]
P = 0.30
ORIG = re.compile(r"^clip_\d{6}\.wav$")


def one(args):
    path, seed = args
    rng = random.Random(seed)
    if rng.random() >= P:
        return 0
    a, sr = sf.read(path, dtype="float32")
    n = len(a)
    with tempfile.TemporaryDirectory() as d:
        if rng.random() < 0.6:
            enc = os.path.join(d, "x.mp3")
            cmd = ["-c:a", "libmp3lame", "-b:a", f"{rng.choice([32, 48, 64, 96, 128])}k", enc]
        else:
            enc = os.path.join(d, "x.ogg")
            cmd = ["-c:a", "libopus", "-b:a", f"{rng.choice([12, 16, 24, 32])}k", enc]
        dec = os.path.join(d, "y.wav")
        try:
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", path, *cmd], check=True)
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", enc,
                            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", dec], check=True)
        except subprocess.CalledProcessError:
            return -1
        b, sr2 = sf.read(dec, dtype="float32")
    if sr2 != 16000 or len(b) == 0:
        return -1
    b = b[:n] if len(b) >= n else np.concatenate([b, np.zeros(n - len(b), np.float32)])
    sf.write(path, b, 16000, subtype="PCM_16")
    return 1


def main():
    for split in SPLITS:
        d = OUT / split
        mark = d / ".codec_done"
        if not d.exists() or mark.exists():
            print(split, "skip"); continue
        files = sorted(str(p) for p in d.iterdir() if ORIG.match(p.name))
        with mp.Pool(os.cpu_count()) as pool:
            res = pool.map(one, [(f, hash((split, i)) & 0xffffffff) for i, f in enumerate(files)], chunksize=64)
        done, failed = sum(1 for r in res if r == 1), sum(1 for r in res if r == -1)
        print(f"{split}: {done}/{len(files)} round-tripped, {failed} failed")
        assert failed < max(10, len(files) // 100), "too many codec failures"
        mark.touch()


if __name__ == "__main__":
    main()
