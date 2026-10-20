"""Fold the owner's own recordings (`Moe --wake-record`) into the training set.

Heads v1–v5 were trained on synthesised speech alone, and VOICE-PLAN.md §8
measured where that ends: v5 added twenty more synthetic voices and got
*worse*, because "a synthesiser's Australian is not an Australian". Real
recordings are the lever that had not been pulled. Usage: real_clips.py

Three things this does that are not obvious, each of which would otherwise be
a silent failure:

1. **It trims long clips from the front, not the back.** The augmenter's
   `align_clip_to_end` keeps the *last* `clip_duration` of anything longer
   than the window (`clip_start = len(audio) - ...`). A 3.9 s recording of
   "Hey Moe, what's on my calendar" would therefore arrive as "…what's on my
   calendar": a clip labelled positive with no wake word in it, teaching the
   head that ordinary speech is the name. Every real positive is cut to the
   first `KEEP` seconds instead, which keeps the name *and* the speech that
   follows it — the property v4 needed, since "Hey Moe" is a prefix of "hey
   mobile" and the policy can only wait for the rest if the training
   positives had a rest.

   Checked, rather than assumed: the shipped head detects **40** of the
   recordings untrimmed and the same **40** after the cut (40/65 vs 40/64 —
   the odd file is the one below `MIN_PEAK`). Trimming from the front costs
   no detections, which is what "the name is still in there" looks like from
   the outside.

2. **It holds a third of them out.** Recall has only ever been measured on
   clips from macOS system voices, so nobody knows what any head does on the
   person who owns the Mac. The held-out third goes to `bench/`, where
   `Moe --wake-bench` counts `positive` paths towards recall and everything
   else towards false accepts. Held out by stride over the prompt order, so
   the bench gets some of every style the recorder asks for (normal, quiet,
   across the room, fast, slow, turned away, whole sentences) rather than a
   random clump.

3. **It repeats them.** Forty-four clips against twelve thousand synthetic
   ones is 0.4% of a positive batch — statistically nothing. Each is written
   `TIMES` times; augmentation gives every copy its own room, noise and EQ,
   so they are not duplicates by the time the model sees them. The risk is
   the model memorising these utterances rather than this voice, and that is
   exactly what the held-out third measures.
"""
import glob
import os
import pathlib
import re
import shutil

import numpy as np
import soundfile as sf

W = pathlib.Path(os.environ.get("WAKE_W", os.path.expanduser("~/moe-wake-train")))
SRC = pathlib.Path(os.environ.get("WAKE_REC", os.path.expanduser("~/.moe/voice/recordings")))
OUT = W / "train/output/hey_moe"
BENCH = W / "bench"

SR = 16000
KEEP = 1.9          # seconds; just under the 2.0 s window, leaving the
                    # augmenter's 200 ms end-jitter somewhere to take from
HOLD_OUT = 3        # every third clip, by prompt order
TIMES = int(os.environ.get("WAKE_REAL_TIMES", 25))  # copies of each training positive
TIMES_CON = int(os.environ.get("WAKE_REAL_CON_TIMES", 25))  # copies of each near miss
TIMES_ROOM = 10     # copies of each window of ordinary speech
MIN_PEAK = 0.05     # below this the recorder should have refused it


def index(path: str) -> int:
    """The prompt number the recorder wrote into the filename, so a split by
    stride follows the script's order (and its styles) rather than the disk's."""
    m = re.search(r"-(\d+)\.wav$", path)
    return int(m.group(1)) if m else 0


def read(path: str) -> np.ndarray | None:
    audio, sr = sf.read(path, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != SR or float(np.max(np.abs(audio))) < MIN_PEAK:
        return None
    return audio


def next_clip_number(folder: pathlib.Path) -> int:
    existing = sorted(glob.glob(str(folder / "clip_*.wav")))
    return 1 + max((int(re.search(r"clip_(\d+)", f).group(1)) for f in existing), default=-1)


def collect(folder: str) -> tuple[list, list]:
    """(training clips, held-out paths) for one recorder folder."""
    paths = sorted(glob.glob(str(SRC / folder / "*.wav")), key=index)
    train, held = [], []
    for n, p in enumerate(paths):
        audio = read(p)
        if audio is None:
            print(f"  skipped (too quiet or wrong rate): {os.path.basename(p)}")
            continue
        (held if n % HOLD_OUT == 0 else train).append((p, audio[: int(KEEP * SR)]))
    return train, [p for p, _ in held]


def write_copies(clips, folder: pathlib.Path, times: int) -> int:
    folder.mkdir(parents=True, exist_ok=True)
    n = next_clip_number(folder)
    for _, audio in clips:
        for _ in range(times):
            sf.write(folder / f"clip_{n:06d}.wav", audio, SR, subtype="PCM_16")
            n += 1
    return len(clips) * times


def hold_out(paths, name: str) -> None:
    """Copy untrimmed, so the bench measures the clip as it was spoken.

    The directory is `real/positive`, not `positive-real`: `--wake-bench`
    counts a file towards recall only when a whole path *component* is
    exactly "positive" (so a `false_positives` folder cannot match), and a
    hyphenated name is silently counted as a negative instead — which reads
    as every real recording being a false accept."""
    d = BENCH / name
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True, exist_ok=True)
    for p in paths:
        shutil.copy2(p, d / os.path.basename(p))
    print(f"  bench/{name}: {len(paths)}")


def room_windows(paths_and_audio) -> list:
    """Ordinary speech, cut into window-sized negatives."""
    out = []
    for p, _ in paths_and_audio:
        audio = read(p)
        if audio is None:
            continue
        step = int(KEEP * SR)
        for i in range(0, max(1, len(audio) - step + 1), step):
            out.append((p, audio[i : i + step]))
    return out


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"no recordings at {SRC} — run `Moe --wake-record` first")

    print("positives")
    pos_train, pos_held = collect("positive")
    hold_out(pos_held, "real/positive")
    print(f"  positive_train += {write_copies(pos_train, OUT / 'positive_train', TIMES)}"
          f" ({len(pos_train)} clips × {TIMES})")

    print("near misses")
    con_train, con_held = collect("confusable")
    hold_out(con_held, "real/confusable")
    print(f"  negative_train += {write_copies(con_train, OUT / 'negative_train', TIMES_CON)}"
          f" ({len(con_train)} clips × {TIMES_CON})")

    print("ordinary speech")
    # Not split: six clips is too few to measure anything, and their value is
    # as negatives — the room, with this voice in it, wanting nothing.
    paths = sorted(glob.glob(str(SRC / "negative" / "*.wav")), key=index)
    windows = room_windows([(p, None) for p in paths])
    print(f"  negative_train += {write_copies(windows, OUT / 'negative_train', TIMES_ROOM)}"
          f" ({len(windows)} windows × {TIMES_ROOM})")


if __name__ == "__main__":
    main()
