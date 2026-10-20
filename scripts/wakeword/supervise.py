"""Run a livekit-wakeword stage that resumes from disk (generate) in
slices: the Piper synthesiser leaks — 17 GB after ~15 000 clips on this
Mac — so each run is killed after `slice` seconds and started again until
one exits 0. Usage: supervise.py <stage> [slice_seconds] — runs in its own
session, writes train/<stage>.supervised.log, exits with the last rc."""
import subprocess, sys, time, os
W = "/path/to/wake"
stage = sys.argv[1]
slice_s = int(sys.argv[2]) if len(sys.argv) > 2 else 420
extra = sys.argv[3:]
log_path = f"{W}/train/{stage}.supervised.log"
rc = 1
for attempt in range(1, 200):
    with open(log_path, "ab") as log:
        log.write(f"\n=== supervise: run {attempt} at {time.strftime('%H:%M:%S')} ===\n".encode())
        log.flush()
        p = subprocess.Popen(["bash", f"{W}/train/run.sh", stage, *extra], stdout=log, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            rc = p.wait(timeout=slice_s)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, 9)
            p.wait()
            log.write(b"=== supervise: slice over, restarting ===\n")
            continue
    if rc == 0:
        break
    time.sleep(5)
with open(log_path, "ab") as log:
    log.write(f"=== supervise: done rc={rc} after {attempt} runs ===\nexit={rc}\n".encode())
sys.exit(rc)
