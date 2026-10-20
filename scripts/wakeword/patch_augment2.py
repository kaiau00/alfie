"""Second local patch to livekit-wakeword 0.2.1's augment.py, on top of
patch_augment.py. Same processing for every class, so nothing but the phrase
separates a positive from a negative (research-wakeword.md §2):

1. SNR drawn from -5..30 dB instead of 5..15 (backgrounds include
   LibriSpeech and AMI meeting speech, so positives get babble under them
   as often as negatives do).
2. A random low-pass (3.4 / 4 / 5.5 / 7 / 8 kHz, p=0.4) — Bluetooth/HFP
   headsets and band-limited sources, and it removes the TTS bandwidth tell.
3. A level change of -12..+6 dB per round (two rounds: down to -24 dB) with a peak limit, so absolute level
   (and the quantisation floor of a quiet clip) is not a class feature.

The codec round-trip is a separate parallel pass over the originals
(codec_pass.py), because ffmpeg per clip inside this single-process loop
would dominate the stage."""
import pathlib
p = pathlib.Path("/opt/venv/lib/python3.12/site-packages/livekit/wakeword/data/augment.py")
s = p.read_text()
assert "(moe) Alignment before the background mix" in s, "run patch_augment.py first"

old = "        snr_db_range: tuple[float, float] = (5.0, 15.0),"
assert s.count(old) == 1
s = s.replace(old, "        snr_db_range: tuple[float, float] = (-5.0, 30.0),")

old2 = """        # Mix with background (moe: after alignment)
        audio = augmentor.mix_with_background(audio)
"""
new2 = """        # Mix with background (moe: after alignment)
        audio = augmentor.mix_with_background(audio)

        # (moe v6) Band limit and level, identical for every class.
        if random.random() < 0.4:
            from scipy.signal import butter, sosfilt
            cutoff = random.choice([3400, 4000, 5500, 7000, 7800])
            sos = butter(8, cutoff, btype="lowpass", fs=sample_rate, output="sos")
            audio = sosfilt(sos, audio).astype(np.float32)
        audio = audio * (10 ** (random.uniform(-12.0, 6.0) / 20))
        peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
        if peak > 0.99:
            audio = audio / peak * 0.99
        audio = audio.astype(np.float32)
"""
assert s.count(old2) == 1
s = s.replace(old2, new2)
assert "sample_rate" in s.split("def _augment_directory")[1].split(")")[0] or "sample_rate" in s
p.write_text(s)
print("patched v6")
