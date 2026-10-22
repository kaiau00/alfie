#!/bin/bash
# Overnight "Hey Alfie" training: every stage after `setup`, in order, each
# skipped once its marker exists so a re-run picks up where it stopped.
# Usage: pipeline.sh   (log: logs/pipeline.log; markers: logs/done.<stage>)
set -u
W=/path/to/wake
RUN="$W/train/run.sh"
PY="$W/venv/bin/python"
LOG="$W/logs/pipeline.log"
cd "$W"

say() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

stage() {
  local name="$1"; shift
  if [ -f "$W/logs/done.$name" ]; then say "skip $name (done)"; return 0; fi
  say "start $name"
  if "$@" >> "$W/logs/$name.log" 2>&1; then
    touch "$W/logs/done.$name"; say "done $name"
  else
    say "FAILED $name (see logs/$name.log)"; exit 1
  fi
}

libri() {
  local raw="$W/librispeech-raw/LibriSpeech"
  # The download runs on its own and unpacks everything at the end; wait
  # (up to 4 hours) until nothing is still downloading or unpacking.
  local waited=0
  while pgrep -f "openslr.org/resources/12" >/dev/null || pgrep -f "tar -xzf" >/dev/null \
        || [ ! -d "$raw/dev-other" ]; do
    [ "$waited" -ge 14400 ] && { echo "LibriSpeech never finished downloading"; return 1; }
    sleep 60; waited=$((waited + 60))
  done
  "$PY" scripts/flac2wav.py "$raw/test-clean" "$W/train/data/librispeech-test-clean" &&
  "$PY" scripts/flac2wav.py "$raw/test-other" "$W/train/data/librispeech-other" &&
  "$PY" scripts/flac2wav.py "$raw/dev-other" "$W/train/data/librispeech-other"
}

# The Piper synthesiser leaks memory, so generate runs in 5-minute slices
# that resume from what is on disk (supervise.py). Short slices for 8 GB.
stage generate    "$PY" scripts/supervise.py generate 300
stage libri       libri
stage onset       bash "$RUN" py "$W/scripts/onset_negatives.py"
stage hard        "$PY" scripts/supervise.py py 300 "$W/scripts/hard_negatives.py"
stage augment     bash "$RUN" augment
stage train       bash "$RUN" train
stage export      bash "$RUN" export
say "pipeline finished"
