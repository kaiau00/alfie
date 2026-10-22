"""Split the Inworld clips (~/moe-wake-data/clips, gen_clips.py) BY VOICE into
training material and a held-out bench, and trim the training half.
Runs on the Mac, before the upload to the training machine.

Held out: ~30 of 282 voices (every 9th voice in a stratified order: English
voices by the accent their description names, others by language), whole
voices only — no clip of a held-out voice reaches training or threshold
choice. The bench gets every clip of those voices, untrimmed:
  bench/inworld/positive/positive_<voice>-NN.wav   ("Hey Alfie", "Hey Alfie, <request>")
  bench/inworld/confusable/confusable_<voice>-NN.wav (near misses: "Hey Joe", "Hey Mona")
  bench/inworld/speech/speech_<voice>-NN.wav   (ordinary sentences, some with
                                           "Alfie"/"mobile"/"moment" inside)
`Alfie --wake-bench` counts a file towards recall only when a path component is
exactly "positive"; the other two count as false accepts.

Training copies: leading/trailing silence cut (energy gate, 60 ms kept), then
the first 1.9 s kept for pos/neg, so a long "Hey Alfie, what's on my calendar"
keeps the name (the augmenter keeps the LAST 2 s of anything longer). Speech
clips are left whole; fold_inworld.py cuts them into windows.
Usage: prep_inworld.py <clips dir> <out dir>   (writes <out>/inworld/{pos,neg,speech},
<out>/bench/inworld/..., <out>/holdout.json)"""
import collections, json, pathlib, random, re, shutil, sys
import numpy as np
import soundfile as sf

SRC = pathlib.Path(sys.argv[1]).expanduser()
OUT = pathlib.Path(sys.argv[2]).expanduser()
VOICES = json.loads((SRC.parent / "inworld-voices.json").read_text())
SR, KEEP, EVERY = 16000, 1.9, 9
ACCENTS = r"(american|british|english|australian|indian|southern|nigerian|singaporean|filipino|irish|scottish|canadian|south african|african)"


def stratum(v):
    langs = v.get("languages") or []
    if "en" in langs:
        m = re.findall(ACCENTS, v.get("description", "").lower())
        return "en:" + (m[0] if m else "unmarked")
    return "xx:" + (langs[0] if langs else "?")


def trim(a):
    frame = 160
    e = np.array([np.sqrt(np.mean(a[i:i + frame] ** 2)) for i in range(0, max(1, len(a) - frame), frame)])
    if not len(e) or e.max() <= 0:
        return a
    on = np.where(e > e.max() * 0.03)[0]
    s = max(0, on[0] * frame - int(0.06 * SR))
    t = min(len(a), (on[-1] + 1) * frame + int(0.06 * SR))
    return a[s:t]


def main():
    rng = random.Random(20260923)
    by = collections.defaultdict(list)
    for v in VOICES:
        by[stratum(v)].append(v["voiceId"])
    order = []
    for k in sorted(by):
        ids = sorted(by[k]); rng.shuffle(ids); order.extend(ids)
    held = set(order[rng.randrange(EVERY)::EVERY])
    strata = collections.Counter(stratum(v) for v in VOICES if v["voiceId"] in held)

    for d in ("inworld", "bench/inworld"):
        shutil.rmtree(OUT / d, ignore_errors=True)
    rows = {}
    for line in (SRC / "manifest.jsonl").read_text().splitlines():
        j = json.loads(line); rows[j["path"]] = j
    n = collections.Counter()
    for path, j in sorted(rows.items()):
        f = SRC / path
        if not f.exists():
            continue
        label = j["label"]                      # pos | neg | speech
        if j["voice"] in held:
            sub = {"pos": "positive", "neg": "confusable", "speech": "speech"}[label]
            # Prefixed: the bench prints bare file names, and "<voice>-NN.wav"
            # exists in all three folders.
            dst = OUT / "bench/inworld" / sub / f"{sub}_{f.name}"
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst); n["bench/" + sub] += 1
            continue
        a, sr = sf.read(f, dtype="float32")
        if a.ndim > 1:
            a = a.mean(axis=1)
        if sr != SR or len(a) < int(0.2 * SR):
            n["skipped"] += 1; continue
        a = trim(a)
        if label != "speech":
            a = a[: int(KEEP * SR)]
        dst = OUT / "inworld" / label / f.name
        dst.parent.mkdir(parents=True, exist_ok=True)
        sf.write(dst, a, SR, subtype="PCM_16"); n["train/" + label] += 1
    (OUT / "holdout.json").write_text(json.dumps(
        {"voices": sorted(held), "strata": dict(strata), "counts": dict(n)}, indent=1))
    print(f"held out {len(held)} voices: {dict(strata)}")
    print(dict(n))


main()
