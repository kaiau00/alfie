#!/bin/bash
# Converts Kokoro's upstream voice packs into the form FluidAudio's ANE build
# loads, and stages them beside the model.
#
# FluidAudio publishes exactly one voice — af_heart.bin — and its own docs say
# "Voices: single per variant". That is true of what it ships and not true of
# what the engine can load. `af_heart.bin` is 522,240 bytes, which is exactly
# 510 × 256 × 4: the raw voice-pack tensor, no header and no container. The 54
# packs in hexgrad/Kokoro-82M are the same tensor inside a thin PyTorch zip,
# so extracting the 522,240-byte blob from a `.pt` produces a byte-identical
# `.bin`.
#
# That is the whole trick, and it is why Moe ships 28 voices instead of one:
#
#     one voice pack          522 KB
#     all 28 English voices    14 MB
#     all 54 voices            27 MB
#     PocketTTS's 19 voices   776 MB
#
# 55× cheaper per voice than the engine it replaced, with nine more of them.
#
# Run this after `fetch-models.sh`; it needs the Kokoro model directory to
# exist. Idempotent — a pack already converted is left alone.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

REPO="hexgrad/Kokoro-82M"
CACHE="$HOME/.cache/fluidaudio/Models/kokoro-82m-coreml/ANE"
WORK="${TMPDIR:-/tmp}/kokoro-voices.$$"
# English only. The other 26 packs are for language variants Moe does not load
# (Japanese and Mandarin need their own model directory and frontend, and the
# European ones need a phonemizer this build has no path to), so shipping them
# would be 13 MB that cannot be selected.
VOICES="af_alloy af_aoede af_bella af_heart af_jessica af_kore af_nicole
        af_nova af_river af_sarah af_sky am_adam am_echo am_eric am_fenrir
        am_liam am_michael am_onyx am_puck am_santa bf_alice bf_emma
        bf_isabella bf_lily bm_daniel bm_fable bm_george bm_lewis"

[ -d "$CACHE" ] || { echo "✗ no Kokoro model at $CACHE — run ./scripts/fetch-models.sh first" >&2; exit 1; }
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

made=0; kept=0
for v in $VOICES; do
  if [ -f "$CACHE/$v.bin" ] && [ "$(stat -f%z "$CACHE/$v.bin")" = "522240" ]; then
    kept=$((kept + 1)); continue
  fi
  curl -sfL --max-time 90 -o "$WORK/$v.pt" \
    "https://huggingface.co/$REPO/resolve/main/voices/$v.pt" \
    || { echo "✗ could not fetch $v" >&2; exit 1; }
  python3 - "$WORK/$v.pt" "$CACHE/$v.bin" <<'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
# 510 rows × 256 columns × 4 bytes. Anything else is not a voice pack, and
# writing it would hand the engine a buffer of the wrong shape.
WANT = 510 * 256 * 4
with zipfile.ZipFile(src) as z:
    blobs = [i.filename for i in z.infolist() if i.file_size == WANT]
    if not blobs:
        sizes = sorted({i.file_size for i in z.infolist()})
        raise SystemExit(f"no {WANT}-byte tensor in {src}; sizes present: {sizes}")
    data = z.read(blobs[0])
assert len(data) == WANT, f"{len(data)} != {WANT}"
open(dst, "wb").write(data)
PY
  made=$((made + 1))
done

echo "✓ Kokoro voices: $made converted, $kept already present"
total=$(du -ch "$CACHE"/*.bin 2>/dev/null | tail -1 | cut -f1)
echo "  $(ls "$CACHE"/*.bin | wc -l | tr -d ' ') packs, $total in $CACHE"
echo
echo "  build.sh copies these into the app with the model. TtsCatalogue lists"
echo "  what Settings offers, so a pack added here must be added there too —"
echo "  KokoroVoiceCatalogueTests checks the two agree."
