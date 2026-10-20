#!/bin/bash
# Accent-diverse training clips from the Mac's system voices that the bench
# does NOT use (bench: Samantha Alex Daniel Karen Moira Fred Rishi Tessa —
# those stay held out). Positives with and without a request after the
# name; the phonetic-neighbour negatives. Written as extra originals; the
# augmenter aligns and mixes them like everything else.
set -eu
W=/path/to/wake
OUT=$W/train/output/hey_moe
TMP=$W/bench/tmp_train; mkdir -p "$TMP"
VOICES=("Aman" "Tara" "Kathy" "Ralph" "Albert" "Junior" "Eddy (English (UK))" "Eddy (English (US))" "Flo (English (UK))" "Flo (English (US))" "Reed (English (UK))" "Reed (English (US))" "Rocko (English (UK))" "Rocko (English (US))" "Sandy (English (UK))" "Sandy (English (US))" "Shelley (English (UK))" "Shelley (English (US))" "Grandma (English (US))" "Grandpa (English (US))")
REQUESTS=("what's the weather like tomorrow?" "remind me at five." "what time is it?" "read my last message." "start a timer for ten minutes." "how do I say this in French?" "open my calendar." "what did I miss?")
NEGS=("Hey mom." "Hey Joe." "Hey no." "Hey mode." "Hey mobile." "Hey more." "Hey bro." "Hey Mo bile." "They know." "Hey home." "Hey Moses." "Hey money." "Hey Monday." "Hey moment." "Hey motion." "Hey you." "Hello." "Okay so.")
say_wav() {  # voice rate text out
  local v=$1 r=$2 text=$3 out=$4
  say -v "$v" -r "$r" -o "$TMP/c.aiff" "$text" 2>/dev/null || return 0
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/c.aiff" "$out" 2>/dev/null || return 0
}
pi=18000; ni=25000; pt=3450; nt=4400
for v in "${VOICES[@]}"; do
  say -v "$v" -o "$TMP/probe.aiff" "hi" 2>/dev/null || { echo "skip $v"; continue; }
  for r in 140 170 200 230; do
    say_wav "$v" "$r" "Hey Moe." "$OUT/positive_train/clip_$(printf %06d $pi).wav"; pi=$((pi+1))
    for q in "${REQUESTS[@]}"; do
      say_wav "$v" "$r" "Hey Moe, $q" "$OUT/positive_train/clip_$(printf %06d $pi).wav"; pi=$((pi+1))
    done
    say_wav "$v" "$r" "Hey Moe, can you help me?" "$OUT/positive_test/clip_$(printf %06d $pt).wav"; pt=$((pt+1))
    for n in "${NEGS[@]}"; do
      say_wav "$v" "$r" "$n" "$OUT/negative_train/clip_$(printf %06d $ni).wav"; ni=$((ni+1))
    done
    say_wav "$v" "$r" "Hey mom, can you help me?" "$OUT/negative_test/clip_$(printf %06d $nt).wav"; nt=$((nt+1))
    say_wav "$v" "$r" "Hey mobile phone." "$OUT/negative_test/clip_$(printf %06d $nt).wav"; nt=$((nt+1))
  done
done
echo "positives $((pi-18000)) test $((pt-3450)) negatives $((ni-25000)) test $((nt-4400))"
