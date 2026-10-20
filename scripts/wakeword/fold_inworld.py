"""Fold the Inworld TTS clips (282 voices, prep_inworld.py) into the training set.

Head v5 showed that more voices from the *same* synthesiser family made the
head worse, not better. Inworld is a different family with real accent
variety (British, Australian, Indian, Nigerian, Singaporean, Filipino, and
123 non-English voices saying the English phrases), so it goes in the way
real_clips.py folds the owner's recordings — with the same three rules:

1. Clips arrive already trimmed by prep_inworld.py: leading/trailing silence
   cut, then the first 1.9 s kept, so "Hey Moe, what's on my calendar" keeps
   the name (the augmenter's align_clip_to_end keeps the LAST 2 s of
   anything longer, which would drop it).
2. Held-out voices never reach this folder; prep_inworld.py split by whole
   voice before anything was written here.
3. They are repeated. ~2 400 positives against 18 000 Piper ones would be a
   modest share; POS_TIMES copies make them ~30% of positive_train. Each copy
   gets its own room/noise/EQ from the augmenter. Short clips (the name
   alone) get a follower of other speech on some copies — v4's lesson: a
   head can only wait out "hey mo-bile" if its positives had speech after
   them too.

Negatives go into negative_train, the adversarial class, the same way.
Indices: positives from 20000, negatives from 30000, speech windows from 45000 — above everything
generate / onset / hard_negatives / append_speech write, so none of their
resume counts moves. real_clips.py runs after this and appends above.
Usage: fold_inworld.py <extra dir>
"""
import pathlib, random, sys
import numpy as np
import soundfile as sf

W = pathlib.Path("/data/wake")
OUT = W / "train/output/hey_moe"
SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else W / "extra/inworld")
SR = 16000
POS_TIMES, NEG_TIMES, SPEECH_TIMES = 2, 2, 2
POS_BASE, NEG_BASE = 20000, 30000
random.seed(23)

speech = sorted((W / "train/data/librispeech-test-clean").glob("*.wav")) + \
    sorted((W / "train/data/librispeech-other").glob("*.wav"))
assert len(speech) > 1000, f"no LibriSpeech for followers ({len(speech)})"


def rms(x):
    return float(np.sqrt(np.mean(x * x)) + 1e-8)


def follower(max_len):
    n = random.randint(int(0.3 * SR), max(int(0.3 * SR) + 1, int(min(1.0, max_len) * SR)))
    a, sr = sf.read(random.choice(speech), dtype="float32")
    assert sr == SR
    if len(a) <= n + SR:
        return a[-n:]
    s = random.randint(int(0.5 * SR), len(a) - n)
    return a[s:s + n]


def with_follower(a):
    room = 1.9 - len(a) / SR
    if room < 0.3:
        return a
    gap = np.zeros(random.randint(0, int(0.12 * SR)), np.float32)
    f = follower(room)
    f = f * (rms(a) * random.uniform(0.6, 1.2) / rms(f))
    out = np.concatenate([a, gap, f]).astype(np.float32)
    peak = float(np.abs(out).max())
    return out / peak * 0.99 if peak > 0.99 else out


def fold(label, split, base, times):
    files = sorted(p for p in (SRC / label).glob("*.wav") if not p.name.startswith("._"))  # no macOS AppleDouble
    assert files, f"no clips in {SRC / label}"
    d = OUT / split
    i, followed = base, 0
    for f in files:
        a, sr = sf.read(f, dtype="float32")
        assert sr == SR, f"{f}: {sr} Hz"
        if a.ndim > 1:
            a = a.mean(axis=1)
        short = len(a) / SR < 1.3
        for k in range(times):
            clip = a
            if short and k >= 1 and random.random() < 0.6:
                clip = with_follower(a)
                followed += 1
            sf.write(d / f"clip_{i:06d}.wav", clip, SR, subtype="PCM_16")
            i += 1
    print(f"{split} += {i - base} from {len(files)} {label} clips × {times} ({followed} with speech after)")


def windows(label, split, base, times):
    """Ordinary Inworld sentences (some with "Moe"/"mobile"/"moment" inside),
    cut into 1.9 s windows at a 1 s hop: the same voices saying things that
    are not the name, so "Inworld timbre" cannot be the positive feature."""
    files = sorted(p for p in (SRC / label).glob("*.wav") if not p.name.startswith("._"))  # no macOS AppleDouble
    assert files, f"no clips in {SRC / label}"
    d = OUT / split
    i, n = base, 0
    for f in files:
        a, sr = sf.read(f, dtype="float32")
        assert sr == SR
        if a.ndim > 1:
            a = a.mean(axis=1)
        win, hop = int(1.9 * SR), SR
        starts = list(range(0, max(1, len(a) - win + 1), hop))
        for s0 in starts:
            w = a[s0:s0 + win]
            if float(np.sqrt(np.mean(w * w))) < 1e-3:
                continue
            n += 1
            for _ in range(times):
                sf.write(d / f"clip_{i:06d}.wav", w, SR, subtype="PCM_16")
                i += 1
    print(f"{split} += {i - base} from {len(files)} {label} clips ({n} windows × {times})")
    return i


# Idempotent on a restart: everything at our indices is ours (real_clips.py
# runs after this stage), so clear it before writing.
for split, base in (("positive_train", POS_BASE), ("negative_train", NEG_BASE)):
    stale = [p for p in (OUT / split).glob("clip_??????.wav") if int(p.stem[5:]) >= base]
    for p in stale:
        p.unlink()
    if stale:
        print(f"{split}: cleared {len(stale)} clips from an earlier attempt")

fold("pos", "positive_train", POS_BASE, POS_TIMES)
fold("neg", "negative_train", NEG_BASE, NEG_TIMES)
windows("speech", "negative_train", 45000, SPEECH_TIMES)
