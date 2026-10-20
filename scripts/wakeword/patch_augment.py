"""Local patch to livekit-wakeword 0.2.1's augment.py (in the venv):
1. Negatives are end-aligned half the time with a 0–800 ms jitter, so
   "silence then a phrase ending near the window's end" is not a shape
   only positives have.
2. Background noise is mixed AFTER alignment, so the padding is room
   noise, never digital silence — a runtime window is never silent.
"""
p = "/path/to/wake/venv/lib/python3.12/site-packages/livekit/wakeword/data/augment.py"
s = open(p).read()
old = """        # Apply RIR
        audio = augmentor.apply_rir(audio)

        # Mix with background
        audio = augmentor.mix_with_background(audio)

        # Align to target duration only on round 0 (raw TTS clips vary in
        # length).  Later rounds already have the correct duration.
        if round_idx == 0:
            if is_positive:
                audio = align_clip_to_end(audio, target_length)
            else:
                # Center-pad or crop negatives
                if len(audio) < target_length:
"""
new = """        # Apply RIR
        audio = augmentor.apply_rir(audio)

        # Align to target duration only on round 0 (raw TTS clips vary in
        # length).  Later rounds already have the correct duration.
        # (moe) Alignment before the background mix, so padding carries
        # noise rather than digital silence; negatives end-aligned half
        # the time with a wide jitter, so the window's shape says nothing.
        if round_idx == 0:
            if is_positive:
                audio = align_clip_to_end(audio, target_length)
            elif random.random() < 0.5:
                audio = align_clip_to_end(audio, target_length, jitter_samples=12800)
            else:
                # Center-pad or crop negatives
                if len(audio) < target_length:
"""
assert s.count(old) == 1
s = s.replace(old, new)
old2 = """                elif len(audio) > target_length:
                    start = (len(audio) - target_length) // 2
                    audio = audio[start : start + target_length]

        # Derive output name"""
new2 = """                elif len(audio) > target_length:
                    start = (len(audio) - target_length) // 2
                    audio = audio[start : start + target_length]

        # Mix with background (moe: after alignment)
        audio = augmentor.mix_with_background(audio)

        # Derive output name"""
assert s.count(old2) == 1
s = s.replace(old2, new2)
open(p, "w").write(s)
print("patched")
