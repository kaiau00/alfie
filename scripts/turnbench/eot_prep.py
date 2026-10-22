#!/usr/bin/env python3
"""Unpack LiveKit's eot-bench (English) into files `Alfie --turn-bench` reads.

The data: https://huggingface.co/datasets/livekit/eot-bench-data — 400 real
English user turns, 16 kHz mono, with word timings and the silence spans
inside each turn. Licence CC-BY-4.0 (attribution: LiveKit, "eot-bench").
It is used here for evaluation only and never enters the repo or the app.

    python3 eot_prep.py <validation-en.parquet> <out-dir>

writes <out-dir>/wav/<id>.wav and <out-dir>/manifest.json:

    [{"id", "duration", "wav", "words": [{"start","end","word"}],
      "silence_spans": [{"start","end"}]}]

Needs pyarrow and soundfile (a scratch venv: `pip install pyarrow soundfile`).
"""
import io
import json
import os
import sys

import pyarrow.parquet as pq
import soundfile as sf


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.join(out, "wav"), exist_ok=True)
    table = pq.read_table(src)
    manifest = []
    for row in table.to_pylist():
        data, rate = sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32")
        if data.ndim > 1:
            data = data.mean(axis=1)
        if rate != 16000:
            print(f"{row['id']}: {rate} Hz, skipped (the bench expects 16 kHz)")
            continue
        name = row["id"].replace("/", "_") + ".wav"
        sf.write(os.path.join(out, "wav", name), data, rate, subtype="PCM_16")
        manifest.append({
            "id": row["id"],
            "duration": row["duration"],
            "wav": "wav/" + name,
            "words": [{"start": w["start"], "end": w["end"], "word": w["word"]} for w in row["words"]],
            "silence_spans": [{"start": s["start"], "end": s["end"]} for s in row["silence_spans"]],
        })
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f)
    print(f"{len(manifest)} turns → {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
