"""'Speech begins' negatives: the first stretch of a LibriSpeech utterance,
end-aligned in a two-second window after silence — the exact shape the
first head fired on. Written as extra negative_train/test clips (2 s, so
the augmenter's padding leaves them alone). Usage: onset_negatives.py"""
import pathlib, random, numpy as np, soundfile as sf
W = pathlib.Path("/path/to/wake")
src = sorted((W / "train/data/librispeech-test-clean").glob("*.wav"))
random.seed(7)
random.shuffle(src)
SR, WIN = 16000, 32000

def write(split, count, files, start_index):
    out = W / "train/output/hey_alfie" / split
    i = start_index
    made = 0
    for f in files:
        if made >= count: break
        audio, sr = sf.read(f, dtype="float32")
        assert sr == SR
        # Trim the utterance's own leading silence roughly (energy gate).
        frame = 320
        e = np.array([np.abs(audio[k:k + frame]).mean() for k in range(0, len(audio) - frame, frame)])
        thr = max(e.max() * 0.05, 1e-4)
        first = next((k for k, v in enumerate(e) if v > thr), 0) * frame
        speech = audio[first:]
        # Two clips per file: 0.4–1.2 s of speech from its start, ending
        # 0–300 ms before the window's end, silence before it.
        for _ in range(2):
            if made >= count: break
            take = random.randint(int(0.4 * SR), int(1.2 * SR))
            take = min(take, len(speech))
            if take < int(0.3 * SR): break
            jitter = random.randint(0, int(0.3 * SR))
            clip = np.zeros(WIN, np.float32)
            end = WIN - jitter
            clip[end - take:end] = speech[:take]
            sf.write(out / f"clip_{i:06d}.wav", clip, SR, subtype="PCM_16")
            i += 1; made += 1
    print(split, "wrote", made, "from", start_index)

write("negative_train", 2000, src[:1500], 8000)
write("negative_test", 300, src[1500:], 1500)
