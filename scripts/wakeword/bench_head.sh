#!/bin/bash
# bench_head.sh <head name> <set name> <dir>… : one --wake-bench pass with traces.
# Sets: recordings (owner, 65 pos + 30 near misses + 6 room), inworld (32
# held-out voices), devclean (LibriSpeech dev-clean, per speaker), ami (AMI
# test meetings, per file). Multi-part sets run one process per part.
set -u
cd "${WAKE_WORK:-$HOME/moe-wake-v6work}"
MOE=${MOE:-$(cd "$(dirname "$0")/../.." && pwd)/.build/debug/Moe}
H=$1; S=$2; shift 2
T=traces/$H-$S.txt
export MOE_WAKE_TRACE=1
: > "$T"
start=$(date +%s)
if [ "$S" = devclean ] || [ "$S" = ami ]; then
  for d in "$@"; do "$MOE" --wake-bench "heads/$H" "$d" >> "$T" 2>&1 || echo "part $d: bench exited non-zero" >> "$T"; done
else
  "$MOE" --wake-bench "heads/$H" "$@" >> "$T" 2>&1 || echo "bench exited non-zero" >> "$T"
fi
echo "ALL DONE in $(( $(date +%s) - start )) s" >> "$T"
tail -3 "$T"
