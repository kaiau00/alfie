"""Positives and neighbour negatives followed by more speech.

"Hey Alfie, what's the weather" is the normal case, and "hey mo-" followed by
"-bile" is the false-accept case; the trainer's positives are the phrase
alone, so a head that waits to hear what follows loses the request and one
that does not wait fires on the neighbours. New originals: an existing
Piper clip, a short gap, then 0.3–1.0 s of other speech (LibriSpeech or a
different TTS clip) at a matched level. The augmenter end-aligns positives
(so the phrase ends 0.3–1.2 s before the window's end) and, patched,
end-aligns half the negatives. Usage: append_speech.py"""
import pathlib, random, numpy as np, soundfile as sf
W = pathlib.Path("/path/to/wake")
OUT = W / "train/output/hey_moe"
SR = 16000
random.seed(11)
speech = sorted((W / "train/data/librispeech-test-clean").glob("*.wav")) + sorted((W / "train/data/librispeech-other").glob("*.wav"))
random.shuffle(speech)

def originals(split, lo, hi):
    return [OUT / split / f"clip_{i:06d}.wav" for i in range(lo, hi) if (OUT / split / f"clip_{i:06d}.wav").exists()]

def rms(x): return float(np.sqrt(np.mean(x * x)) + 1e-8)

def follower(tts_pool, max_len):
    n = random.randint(int(0.3 * SR), int(min(1.0, max_len) * SR))
    if random.random() < 0.5 and tts_pool:
        a, sr = sf.read(random.choice(tts_pool), dtype="float32")
        assert sr == SR
        return a[:n]
    f = random.choice(speech)
    a, sr = sf.read(f, dtype="float32")
    assert sr == SR
    if len(a) <= n + SR: return a[-n:]
    start = random.randint(int(0.5 * SR), len(a) - n)
    return a[start:start + n]

def make(src_files, tts_pool, split, first_index, count):
    i = first_index
    made = 0
    while made < count:
        src = random.choice(src_files)
        a, sr = sf.read(src, dtype="float32")
        assert sr == SR
        if a.ndim > 1: a = a[:, 0]
        room = 1.9 - len(a) / SR
        if room < 0.3: continue
        gap = np.zeros(random.randint(0, int(0.12 * SR)), np.float32)
        f = follower(tts_pool, room)
        f = f * (rms(a) * random.uniform(0.6, 1.2) / rms(f))
        out = np.concatenate([a, gap, f]).astype(np.float32)
        peak = np.abs(out).max()
        if peak > 0.99: out = out / peak * 0.99
        sf.write(OUT / split / f"clip_{i:06d}.wav", out, SR, subtype="PCM_16")
        i += 1; made += 1
    print(split, "wrote", made, "from", first_index)

pos_train = originals("positive_train", 0, 12000)
pos_test = originals("positive_test", 0, 2450)
neg_all_train = originals("negative_train", 0, 12000)          # adversarial + phonetic neighbours
hard_train = originals("negative_train", 15000, 21000)
hard_test = originals("negative_test", 3000, 3800)
make(pos_train, neg_all_train, "positive_train", 12000, 6000)
make(pos_test, neg_all_train, "positive_test", 2450, 1000)
make(hard_train + neg_all_train[:3000], neg_all_train, "negative_train", 21000, 4000)
make(hard_test, neg_all_train, "negative_test", 3800, 600)
