#!/bin/bash
# Held-out clips from the Mac's own voices (a different synthesiser from the
# Piper voices the head is trained on): positives, positives followed by a
# request in the same breath, and confusable negatives. 16 kHz mono WAV,
# with a second of silence either side so the two-second window matters.
set -eu
B=/path/to/wake/bench
mkdir -p "$B/positive" "$B/confusable"
VOICES="Samantha Alex Daniel Karen Moira Fred Rishi Tessa"
say_clip() {  # dir name voice rate text
  local dir=$1 name=$2 voice=$3 rate=$4 text=$5
  local aiff="$B/tmp_$name.aiff"
  say -v "$voice" -r "$rate" -o "$aiff" "$text" 2>/dev/null || return 0
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$B/tmp_$name.wav"
  # pad: 1 s silence, clip, 1 s silence
  "$B/../venv/bin/python" - "$B/tmp_$name.wav" "$dir/$name.wav" <<'PY'
import sys, wave, numpy as np
src, dst = sys.argv[1], sys.argv[2]
with wave.open(src) as w:
    pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
z = np.zeros(16000, np.int16)
out = np.concatenate([z, pcm, z])
with wave.open(dst, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(out.tobytes())
PY
  rm -f "$aiff" "$B/tmp_$name.wav"
}
i=0
for v in $VOICES; do
  for r in 150 190 230; do
    i=$((i+1))
    say_clip "$B/positive" "heymoe_${v}_${r}" "$v" "$r" "Hey Moe."
    say_clip "$B/positive" "heymoe_ask_${v}_${r}" "$v" "$r" "Hey Moe, what's the weather like tomorrow?"
    say_clip "$B/positive" "heymoe_mid_${v}_${r}" "$v" "$r" "So anyway. Hey Moe, remind me at five."
  done
done
for v in Samantha Alex Daniel Karen; do
  for phrase in "Hey no." "Hey Joe." "Hey Mom." "Moe." "Hey mode." "Hey, more." "Hey, you." "Hey bro." "They know." "Hey Mo bile." "Hello." "Hey Siri."; do
    n=$(echo "$phrase" | tr -cd 'A-Za-z' | tr 'A-Z' 'a-z')
    say_clip "$B/confusable" "${n}_${v}" "$v" 180 "$phrase"
  done
done
ls "$B/positive" | wc -l; ls "$B/confusable" | wc -l
