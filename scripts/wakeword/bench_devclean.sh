#!/bin/bash
# The false-accept bench over LibriSpeech dev-clean, one speaker directory
# per run so a killed process loses minutes, not hours; all runs append to
# one trace (sweep_policy.py sums the "false accepts" lines' hours).
# Usage: bench_devclean.sh <head dir> <trace file>
set -u
HEAD=$1; TRACE=$2
W=/path/to/wake
MOE=/path/to/memoe/.build/debug/Moe
export MOE_WAKE_TRACE=1
: > "$TRACE"
for d in "$W"/bench/LibriSpeech/dev-clean/*/; do
  spk=$(basename "$d")
  if ! "$MOE" --wake-bench "$HEAD" "$d" >> "$TRACE" 2>&1; then
    echo "speaker $spk: bench exited non-zero" >> "$TRACE"
  fi
done
echo "ALL SPEAKERS DONE" >> "$TRACE"
