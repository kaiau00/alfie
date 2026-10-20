#!/bin/bash
# Run a training stage in its own session (macOS has no setsid; Python's
# start_new_session does the same), so the caller's process-group kill
# cannot reach it. Log: train/<stage>.detached.log
W=/path/to/wake
stage="$1"; shift
log="$W/train/$stage.detached.log"
/usr/bin/python3 - "$W/train/run.sh" "$stage" "$log" "$@" <<'PY'
import subprocess, sys
run, stage, log, *rest = sys.argv[1:]
with open(log, "ab") as out:
    p = subprocess.Popen(["bash", run, stage, *rest], stdout=out, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, start_new_session=True)
print("pid", p.pid, "log", log)
PY
