#!/usr/bin/env python3
"""Fetch the noise and room-impulse sources the turn corpus is mixed with.

Commercial use allowed only — Moe is a paid product, and these clips may end
up in training (research-noise.md, research-eval-harness.md §4.1):

  DEMAND (CC BY-SA 3.0)      zenodo.org/records/1227121, the 16 kHz zips; channel 1
                             of each environment is kept
  OpenSLR SLR28 (Apache-2.0) www.openslr.org/28 — point-source noises and real RIRs
  MUSAN (OpenSLR 17)         a sample of the noise files from the FluidInference/musan
                             mirror on Hugging Face (it has no music or speech). MUSAN's
                             licence is per file; its own LICENSE lists are read
                             and anything marked NC or ND, or unmarked, is skipped
  LibriSpeech dev-clean      (CC BY 4.0) other people talking, strung into beds

Never WHAM! or ESC-50 (CC BY-NC).

    python3 fetch_noise.py [<out-dir>]        # default ~/moe-voice-data/noise

Resumable: whatever is already on disk is kept. Writes <out>/sources.json —
one row per usable file with its category, source and licence — which is
what mix.py reads. Needs numpy and soundfile.
"""
import concurrent.futures as cf
import io
import json
import pathlib
import random
import re
import sys
import urllib.request
import zipfile

import numpy as np
import soundfile as sf

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "moe-voice-data/noise")
SR = 16000

# DEMAND environments a person talks to a Mac in, and one it does not
# (the washing machine is a steady machine hum; the cafeteria is babble).
DEMAND = {"DKITCHEN": "kitchen", "DLIVING": "living", "DWASHING": "appliance",
          "OOFFICE": "office", "PCAFETER": "babble"}
ZENODO = "https://zenodo.org/records/1227121/files/{}_16k.zip?download=1"
SLR28 = "https://www.openslr.org/resources/28/rirs_noises.zip"
HF = "https://huggingface.co/datasets/FluidInference/musan/resolve/main/{}"
HF_TREE = "https://huggingface.co/api/datasets/FluidInference/musan/tree/main/{}"
# How many MUSAN files of each kind to take (they are long: minutes each).
# The Hugging Face mirror carries MUSAN's noise only: music/ and speech/ hold
# just their LICENSE and ANNOTATIONS files (checked 2026-09-23), and the full
# tarball is 11 GB. So there is no music bed yet, and the other-talker / TV
# bed is LibriSpeech (below).
MUSAN = {"noise/free-sound": 40, "noise/sound-bible": 20}
# Other voices in the room: LibriSpeech dev-clean (CC BY 4.0), already on
# this Mac from the wake-word bench. Utterances from different speakers are
# strung together into one-minute beds.
LIBRISPEECH = pathlib.Path.home() / "moe-wake-v6work/bench/LibriSpeech/dev-clean"
NC = re.compile(r"\b(NC|ND|non-?commercial|noncommercial|no ?deriv)", re.I)


def fetch(url, dest):
    """Download to `dest`, resuming a `.part` left by an earlier run — and
    resuming again when a connection closes early. A server that drops the
    stream ends it cleanly as far as urllib can tell: without the length
    check, a 1.3 GB zip came down as 314 MB and was renamed as finished."""
    dest = pathlib.Path(dest)
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    total = None
    for _ in range(50):
        have = tmp.stat().st_size if tmp.exists() else 0
        if total is not None and have >= total:
            break
        req = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                if have and r.status == 206:
                    mode = "ab"
                    cr = r.headers.get("Content-Range", "")
                    total = int(cr.rsplit("/", 1)[1]) if "/" in cr and cr.rsplit("/", 1)[1].isdigit() else total
                else:
                    mode = "wb"
                    n = r.headers.get("Content-Length")
                    total = int(n) if n and n.isdigit() else None
                with open(tmp, mode) as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
        except Exception as e:
            print(f"  {dest.name}: {type(e).__name__}, resuming", flush=True)
            continue
        if total is None:
            break
    if total is not None and tmp.stat().st_size != total:
        raise RuntimeError(f"{dest.name}: {tmp.stat().st_size} of {total} bytes")
    tmp.rename(dest)
    return dest


def mono16(path):
    y, sr = sf.read(str(path), dtype="float32", always_2d=True)
    y = y[:, 0]
    if sr != SR:
        # Linear resampling is enough for noise beds; none of the sources
        # here should need it (all are 16 kHz), so say so when one does.
        print(f"  resampling {path.name} {sr}→{SR}")
        t = np.arange(int(len(y) * SR / sr)) * sr / SR
        y = np.interp(t, np.arange(len(y)), y).astype(np.float32)
    return y


def demand_env(env, cat):
    wav = OUT / "demand" / f"{env}_ch01.wav"
    if not wav.exists():
        z = fetch(ZENODO.format(env), OUT / "_dl" / f"{env}_16k.zip")
        with zipfile.ZipFile(z) as zf:
            name = next(n for n in zf.namelist() if n.endswith("ch01.wav"))
            y, sr = sf.read(io.BytesIO(zf.read(name)), dtype="float32")
            assert sr == SR, (env, sr)
            wav.parent.mkdir(parents=True, exist_ok=True)
            sf.write(str(wav), y, SR, subtype="PCM_16")
        z.unlink()
    return [{"path": str(wav.relative_to(OUT)), "category": cat, "source": "DEMAND",
             "licence": "CC BY-SA 3.0", "kind": "noise"}]


def slr28():
    rows = []
    root = OUT / "slr28"
    if not (root / "RIRS_NOISES").exists():
        z = fetch(SLR28, OUT / "_dl" / "rirs_noises.zip")
        with zipfile.ZipFile(z) as zf:
            for n in zf.namelist():
                if n.startswith(("RIRS_NOISES/pointsource_noises/", "RIRS_NOISES/real_rirs_isotropic_noises/")) \
                        and n.endswith(".wav"):
                    zf.extract(n, root)
        z.unlink()
    for p in sorted((root / "RIRS_NOISES/pointsource_noises").glob("*.wav")):
        rows.append({"path": str(p.relative_to(OUT)), "category": "pointsource", "source": "SLR28",
                     "licence": "Apache-2.0", "kind": "noise"})
    # Real RIRs, single channel (the multi-channel arrays are skipped).
    for p in sorted((root / "RIRS_NOISES/real_rirs_isotropic_noises").glob("*.wav")):
        name = p.name.lower()
        if "noise" in name:
            continue
        info = sf.info(str(p))
        if info.channels != 1 or info.samplerate != SR:
            continue
        rows.append({"path": str(p.relative_to(OUT)), "category": "rir", "source": "SLR28",
                     "licence": "Apache-2.0", "kind": "rir"})
    return rows


def librispeech_beds(n=12, seconds=60.0):
    rows = []
    files = sorted(LIBRISPEECH.glob("*/*/*.flac")) if LIBRISPEECH.exists() else []
    if not files:
        print("  LibriSpeech dev-clean not found: no other-talker bed", flush=True)
        return rows
    rng = random.Random(20260923)
    for k in range(n):
        wav = OUT / "librispeech" / f"talk-{k:02d}.wav"
        if not wav.exists():
            parts, total = [], 0
            while total < seconds * SR:
                y, sr = sf.read(str(rng.choice(files)), dtype="float32")
                assert sr == SR
                gap = np.zeros(int(rng.uniform(0.2, 0.8) * SR), np.float32)
                parts += [y, gap]
                total += len(y) + len(gap)
            wav.parent.mkdir(parents=True, exist_ok=True)
            sf.write(str(wav), np.concatenate(parts)[:int(seconds * SR)], SR, subtype="PCM_16")
        rows.append({"path": str(wav.relative_to(OUT)), "category": "tv-speech",
                     "source": "LibriSpeech dev-clean", "licence": "CC BY 4.0", "kind": "noise"})
    return rows


ID = re.compile(r"\b((?:music|noise|speech)-[a-z-]+-\d{4})\b")
LICENCE_LINE = re.compile(r"(CC[ -]|Creative Commons|Attribution|Public Domain|License:|Licence:)", re.I)


def musan_licences(folder):
    """(per-file {name.wav: licence}, a folder-wide licence or None) from
    MUSAN's own LICENSE file. Its blocks are separated by lines of '=' and
    name one or more files, then the licence they share."""
    try:
        text = urllib.request.urlopen(HF.format(folder + "/LICENSE"), timeout=60).read().decode("utf-8", "replace")
    except Exception:
        return {}, None
    out = {}
    for block in re.split(r"\n=+\s*\n", text):
        ids = ID.findall(block)
        lic = [l.strip() for l in block.splitlines() if LICENCE_LINE.search(l) and not ID.search(l)]
        for i in ids:
            out[i + ".wav"] = "; ".join(lic)
    folder_wide = None
    if not out and re.search(r"public domain", text, re.I):
        folder_wide = "Public Domain (folder-wide, per MUSAN LICENSE)"
    return out, folder_wide


def musan_folder(folder, n):
    rows = []
    rng = random.Random(f"20260923-{folder}")
    listing = json.load(urllib.request.urlopen(HF_TREE.format(folder), timeout=60))
    files = sorted(x["path"] for x in listing if x["path"].endswith(".wav"))
    licences, folder_wide = musan_licences(folder)
    top = folder.split("/")[0]
    category = {"noise": "musan-noise", "music": "music", "speech": "tv-speech"}[top]
    picked = 0
    for path in rng.sample(files, len(files)):
        if picked >= n:
            break
        name = path.split("/")[-1]
        lic = licences.get(name) or folder_wide or ""
        # Unknown is not "allowed": a file with no licence line is skipped.
        if not lic or NC.search(lic):
            continue
        dest = OUT / "musan" / path
        try:
            fetch(HF.format(path), dest)
        except Exception as e:
            print(f"  {path}: {e}")
            continue
        picked += 1
        rows.append({"path": str(dest.relative_to(OUT)), "category": category, "source": "MUSAN",
                     "licence": lic, "kind": "noise"})
    print(f"  MUSAN {folder}: {picked} files ({len(licences)} licence rows read"
          f"{', folder-wide: ' + folder_wide if folder_wide else ''})", flush=True)
    return rows


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # Side by side: each server is slow on its own (zenodo ~0.2 MB/s here).
    jobs = [(demand_env, (env, cat)) for env, cat in DEMAND.items()] + [(slr28, ())] \
        + [(musan_folder, (f, n)) for f, n in MUSAN.items()] + [(librispeech_beds, ())]
    rows = []
    with cf.ThreadPoolExecutor(len(jobs)) as ex:
        for got in ex.map(lambda j: j[0](*j[1]), jobs):
            rows += got
    (OUT / "sources.json").write_text(json.dumps(rows, indent=1))
    by = {}
    for r in rows:
        by[r["category"]] = by.get(r["category"], 0) + 1
    print(f"{len(rows)} sources → {OUT / 'sources.json'}: {by}")


if __name__ == "__main__":
    main()
