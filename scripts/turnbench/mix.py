#!/usr/bin/env python3
"""Mix the rendered turn corpus into scenarios `Alfie --turn-bench --corpus` reads.

    python3 mix.py <raw-dir> <noise-dir> <out-dir> [--split test|dev] [--snrs clean,20,10,5,0]

<raw-dir> is what ~/moe-wake-data/turn_corpus.py rendered (a WAV and a JSON
with Inworld's word timings per line); <noise-dir> is fetch_noise.py's output
(sources.json). Writes <out-dir>/wav/<id>.wav and <out-dir>/manifest.json.

Two kinds of scenario (research-eval-harness.md §3.5–3.6, §4.1):

  turn   Alfie is listening and the person says one line (single, pause,
         filler, and, correction, short). Truth: every word's time, the
         pauses they went on after (`holds`, gaps ≥ 0.2 s between words) and
         the true end (`end`, last word's end to the end of the file).
         0.6 s lead-in, 8 s tail, both carrying the noise.

  reply  Alfie is talking (one of its own replies, in its own Inworld voice) and
         the person says a stop word, a real interruption, a backchannel —
         or nothing at all (`none`), for the false barge-in rate. The reply
         is the timeline a barge-in lands on; played back into the
         microphone at `echoDb` below the person's speech level it is also
         the simulated echo (the residual after the canceller: VPIO cannot
         run offline). The interjection lands 0.5, 1.5 or 4 s into the reply.

Every base scenario is mixed at each SNR in the grid with the same noise
segment, room and levels, so the SNR is the only thing that changes between
its copies (paired comparisons). SNR is measured over the person's speech-
active samples only (inside word spans), as the DNS Challenge does; the
person's level is drawn from −32 to −20 dBFS. Half the base scenarios put the
person in a real room (an SLR28 RIR, aligned on its direct path so the word
times still hold). "clean" has no noise, only −80 dBFS dither so no model
ever sees digital zero.

Everything is seeded by the scenario id: a rerun makes the same files.
Needs numpy and soundfile.
"""
import argparse
import hashlib
import json
import pathlib
import random

import numpy as np
import soundfile as sf

SR = 16000
TURN_CATS = ("single", "pause", "filler", "and", "correction", "short")
REPLY_CATS = ("stop", "interrupt", "backchannel")
# No music yet: the MUSAN mirror fetch_noise.py uses has none (see there).
NOISE_CATS = ("kitchen", "living", "appliance", "office", "babble", "pointsource", "musan-noise",
              "tv-speech")
OFFSETS = (0.5, 1.5, 4.0)
ECHO_DB = (None, -25.0, -15.0)
LEAD, TAIL, REPLY_TAIL = 0.6, 8.0, 1.0


def seed(*parts):
    return int(hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()[:12], 16)


def real_words(tokens):
    """Inworld's tokens are words, spaces, punctuation and the break tag; keep
    words, and mark the last word of each sentence (a '.', '?' or '!' token or
    ending follows it) — where one piece of a reply hands over to the next."""
    out = []
    for t in tokens:
        w = t["word"].strip()
        if w.startswith("<"):
            continue
        if any(c.isalnum() for c in w):
            out.append({"word": w, "start": t["start"], "end": t["end"]})
            if w[-1] in ".?!":
                out[-1]["sentenceEnd"] = True
        elif out and any(c in w for c in ".?!"):
            out[-1]["sentenceEnd"] = True
    return out


def load(raw, rid):
    y, sr = sf.read(str(raw / f"{rid}.wav"), dtype="float32", always_2d=True)
    assert sr == SR, (rid, sr)
    meta = json.loads((raw / f"{rid}.json").read_text())
    return y[:, 0], meta


def active_power(y, words, offset):
    idx = np.zeros(len(y), bool)
    for w in words:
        a, b = int((w["start"] + offset) * SR), int((w["end"] + offset) * SR)
        idx[max(0, a):min(len(y), b)] = True
    seg = y[idx] if idx.any() else y
    return float(np.mean(seg.astype(np.float64) ** 2)) + 1e-12


def db(p):
    return 10 * np.log10(p)


def convolve_rir(y, rir):
    rir = rir / (np.max(np.abs(rir)) + 1e-9)
    peak = int(np.argmax(np.abs(rir)))
    rir = rir[peak:]                       # aligned on the direct path
    n = len(y) + len(rir) - 1
    size = 1 << (n - 1).bit_length()
    out = np.fft.irfft(np.fft.rfft(y, size) * np.fft.rfft(rir, size), size)[:len(y)]
    return out.astype(np.float32)


class Noise:
    def __init__(self, root):
        self.root = pathlib.Path(root)
        rows = json.loads((self.root / "sources.json").read_text())
        self.by_cat = {}
        for r in rows:
            if r["kind"] == "noise":
                self.by_cat.setdefault(r["category"], []).append(r)
        self.rirs = [r for r in rows if r["kind"] == "rir"]
        self.cache = {}

    def audio(self, row):
        p = row["path"]
        if p not in self.cache:
            y, sr = sf.read(str(self.root / p), dtype="float32", always_2d=True)
            assert sr == SR, (p, sr)
            self.cache[p] = y[:, 0]
        return self.cache[p]

    def segment(self, rng, cat, n):
        pool = self.by_cat.get(cat) or [r for rs in self.by_cat.values() for r in rs]
        row = rng.choice(pool)
        y = self.audio(row)
        # Skip near-silent stretches: find a start whose segment has energy.
        for _ in range(8):
            if len(y) >= n:
                a = rng.randrange(0, len(y) - n + 1)
                seg = y[a:a + n]
            else:
                seg = np.tile(y, n // max(1, len(y)) + 1)[:n]
            if np.mean(seg.astype(np.float64) ** 2) > 1e-9:
                break
        return seg.copy(), row

    def rir(self, rng):
        row = rng.choice(self.rirs)
        return self.audio(row), row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw"); ap.add_argument("noise"); ap.add_argument("out")
    ap.add_argument("--split", default="test")
    ap.add_argument("--snrs", default="clean,20,10,5,0")
    a = ap.parse_args()
    raw, out = pathlib.Path(a.raw).expanduser(), pathlib.Path(a.out).expanduser()
    (out / "wav").mkdir(parents=True, exist_ok=True)
    noise = Noise(pathlib.Path(a.noise).expanduser())
    snrs = [None if s == "clean" else float(s) for s in a.snrs.split(",")]

    metas = {p.stem: json.loads(p.read_text()) for p in raw.glob("*.json") if p.stem != "ledger"}
    lines = sorted((m for m in metas.values() if m["split"] == a.split), key=lambda m: m["id"])
    replies = sorted(m["id"] for m in metas.values() if m["category"] == "reply")
    if not replies:
        raise SystemExit("no Alfie replies rendered")

    bases = []   # (id, kind, category, line-id or None, voice)
    for m in lines:
        if m["category"] in TURN_CATS:
            bases.append((m["id"], "turn", m["category"], m["id"], m["voice"]))
        elif m["category"] in REPLY_CATS:
            bases.append((m["id"], "reply", m["category"], m["id"], m["voice"]))
    for v in sorted({m["voice"] for m in lines}):
        bases.append((f"{a.split}-{v}-none-00", "reply", "none", None, v))

    scenarios = []
    for n, (bid, kind, cat, lid, voice) in enumerate(bases):
        rng = random.Random(seed(bid))
        level = rng.uniform(-32, -20)
        cat_noise = NOISE_CATS[n % len(NOISE_CATS)]
        use_rir = rng.random() < 0.5
        user, words = None, []
        if lid:
            user, meta = load(raw, lid)
            words = real_words(meta["words"])
            if not words:
                print(f"  {lid}: no word timings, skipped"); continue
            if use_rir and noise.rirs:
                rir, rir_row = noise.rir(rng)
                user = convolve_rir(user, rir)
            # Trim the render to its last word (plus 50 ms): the tail is the
            # scenario's own, with noise in it.
            user = user[:int((words[-1]["end"] + 0.05) * SR)]
        if kind == "turn":
            start = LEAD
            total = int((LEAD + len(user) / SR + TAIL) * SR)
            track = np.zeros(total, np.float32)
            track[int(start * SR):int(start * SR) + len(user)] = user
            reply_info, inter = None, None
            echo = np.zeros(total, np.float32)
            echo_db = None
        else:
            rid = replies[rng.randrange(len(replies))]
            rep, rmeta = load(raw, rid)
            rwords = real_words(rmeta["words"])
            r0 = 0.5
            # Drawn per scenario: a fixed cycle over the base order lined the
            # echo level up with the category (every stop got −15 dB).
            offset = rng.choice(OFFSETS) + rng.uniform(0, 0.3)
            echo_db = rng.choice(ECHO_DB)
            if user is not None:
                u0 = r0 + offset
                u_end = u0 + len(user) / SR
                r_end = min(r0 + len(rep) / SR, u_end + 4.0)
            else:
                u0 = u_end = None
                r_end = r0 + len(rep) / SR
            total = int((r_end + REPLY_TAIL) * SR)
            track = np.zeros(total, np.float32)
            if user is not None:
                a0 = int(u0 * SR)
                seg = user[:max(0, total - a0)]
                track[a0:a0 + len(seg)] = seg
            rep = rep[:int((r_end - r0) * SR)].copy()
            fade = min(len(rep), int(0.05 * SR))
            if fade:
                rep[-fade:] *= np.linspace(1, 0, fade, dtype=np.float32)
            echo = np.zeros(total, np.float32)
            reply_words = [w for w in rwords if w["start"] + r0 < r_end]
            if echo_db is not None:
                d = int(0.03 * SR)       # speaker → canceller residual, ~30 ms late
                a0 = int(r0 * SR) + d
                seg = rep[:max(0, total - a0)]
                echo[a0:a0 + len(seg)] = seg
            reply_info = {"start": r0, "end": r_end, "voice": rmeta["voice"], "line": rid,
                          "words": [{"word": w["word"], "start": round(w["start"] + r0, 4),
                                     "end": round(w["end"] + r0, 4),
                                     **({"sentenceEnd": True} if w.get("sentenceEnd") else {})}
                                    for w in reply_words]}
            start = u0
            inter = None
            if user is not None:
                inter = {"kind": cat, "text": metas[lid]["text"], "start": round(u0 + words[0]["start"], 4),
                         "end": round(u0 + words[-1]["end"], 4)}
        # Levels: the person at `level` dBFS over their speech; echo relative to it.
        if user is not None:
            p_user = active_power(track, words, start)
            track *= np.float32(10 ** ((level - db(p_user)) / 20))
            p_user = 10 ** (level / 10)
        else:
            p_user = 10 ** (level / 10)
        if echo_db is not None and reply_info:
            p_echo = active_power(echo, reply_info["words"], 0.03)
            echo *= np.float32(10 ** ((level + echo_db - db(p_echo)) / 20))
        nseg, nrow = noise.segment(rng, cat_noise, total)
        p_noise = float(np.mean(nseg.astype(np.float64) ** 2)) + 1e-12
        dither = np.random.default_rng(seed(bid, "dither")).standard_normal(total).astype(np.float32) * 1e-4
        base_words = [{"word": w["word"], "start": round(w["start"] + start, 4), "end": round(w["end"] + start, 4)}
                      for w in words] if user is not None else []
        for snr in snrs:
            mix = track + echo + dither
            if snr is not None:
                gain = np.sqrt(p_user / (p_noise * 10 ** (snr / 10)))
                mix = mix + nseg * np.float32(gain)
                p_n_scaled = p_noise * gain ** 2
            else:
                p_n_scaled = 0.0
            peak = float(np.max(np.abs(mix)))
            scale = 0.99 / peak if peak > 0.99 else 1.0
            mix = (mix * scale).astype(np.float32)
            sid = f"{bid}@{'clean' if snr is None else int(snr)}"
            sf.write(str(out / "wav" / f"{sid}.wav"), mix, SR, subtype="PCM_16")
            row = {
                "id": sid, "base": bid, "wav": f"wav/{sid}.wav", "kind": kind, "category": cat,
                "split": a.split, "voice": voice, "snr": snr, "noise": None if snr is None else cat_noise,
                "noiseFile": None if snr is None else nrow["path"], "rir": bool(user is not None and use_rir),
                "echoDb": echo_db, "levelDb": round(level, 2), "duration": round(total / SR, 4),
                # What the engine's loudness check divides by: the person's
                # voice as the session opened, room included.
                "referenceRms": round(float(np.sqrt(p_user + p_n_scaled)) * scale, 6),
                "words": base_words,
            }
            if kind == "turn":
                gaps = [{"start": base_words[i]["end"], "end": base_words[i + 1]["start"]}
                        for i in range(len(base_words) - 1)
                        if base_words[i + 1]["start"] - base_words[i]["end"] >= 0.2 - 1e-9]
                row["holds"] = gaps
                row["end"] = {"start": base_words[-1]["end"], "end": round(total / SR, 4)}
                row["text"] = metas[lid]["text"]
            else:
                row["reply"] = reply_info
                row["interjection"] = inter
            scenarios.append(row)
        if (n + 1) % 50 == 0:
            print(f"  {n + 1}/{len(bases)} base scenarios")
    manifest = {"version": 1, "sampleRate": SR, "split": a.split, "snrs": a.snrs.split(","),
                "scenarios": scenarios}
    (out / "manifest.json").write_text(json.dumps(manifest))
    kinds = {}
    for s in scenarios:
        kinds[(s["kind"], s["category"])] = kinds.get((s["kind"], s["category"]), 0) + 1
    hours = sum(s["duration"] for s in scenarios) / 3600
    print(f"{len(scenarios)} scenarios ({len(bases)} bases × {len(snrs)} SNRs), {hours:.2f} h → {out}")
    print(" ".join(f"{k}/{c}:{v}" for (k, c), v in sorted(kinds.items())))


if __name__ == "__main__":
    main()
