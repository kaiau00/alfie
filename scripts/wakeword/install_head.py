"""Copy the trained classifier into the repo and write its sidecar from the
training run's metrics. Usage: install_head.py [hits] [strong] [threshold]
— overrides come from the bench; without them the trainer's optimal
threshold is used, hits=2, strong default (0.95)."""
import json, shutil, sys, datetime, pathlib
W = pathlib.Path("/path/to/wake")
import os
# HEAD_SRC picks a parked run (train/output/hey_alfie-vN) instead of the live one.
OUT = pathlib.Path(os.environ.get("HEAD_SRC") or (W / "train/output/hey_alfie"))
# The checkout this script is in, unless HEAD_DST names another on purpose.
# (It used to name a worktree 214 commits behind main: a head installed there
# was correct, tested and invisible.)
DST = pathlib.Path(os.environ.get("HEAD_DST") or pathlib.Path(__file__).resolve().parents[2] / "Resources/WakeWord")
if not (DST / "embedding_model.onnx").exists() or not (DST / "melspectrogram.onnx").exists():
    raise SystemExit(f"{DST} has no WakeWord resources — refusing to install a head there")

metrics = json.loads((OUT / "hey_alfie_metrics.json").read_text())
optimal = next((m for m in reversed(metrics) if m.get("note") == "optimal_threshold"), None)
final = next((m for m in reversed(metrics) if m.get("note") == "final_averaged"), None)
threshold = float(sys.argv[3]) if len(sys.argv) > 3 else float(optimal["threshold"] if optimal else 0.5)
hits = int(sys.argv[1]) if len(sys.argv) > 1 else 2
strong = float(sys.argv[2]) if len(sys.argv) > 2 else None

shutil.copyfile(OUT / "hey_alfie.onnx", DST / "hey-alfie.onnx")
sidecar = {
    "phrases": ["hey alfie", "hey alfy", "hey alfee"],
    "threshold": round(threshold, 3),
    "hits": hits,
    "trained": datetime.date.today().isoformat(),
    "training": {
        "pipeline": os.environ.get("PIPELINE", "livekit-wakeword 0.2.1, --skip-acav, LibriSpeech test-clean negatives"),
        "model": "conv_attention medium",
        "validation": {k: optimal.get(k) for k in ("threshold", "fpph", "recall")} if optimal else None,
        "final": {k: final.get(k) for k in ("fpph", "recall", "accuracy")} if final else None,
    },
}
if strong is not None:
    sidecar["strong"] = strong
# The numbers the shipped policy was set from (sweep_policy.py over the
# bench traces), so the file can be audited on its own. Set from the
# environment: BENCH="recall=56/72 confusables=6/48 devclean=5/5.35h".
import os
if os.environ.get("BENCH"):
    sidecar["bench"] = os.environ["BENCH"]
(DST / "hey-alfie.json").write_text(json.dumps(sidecar, indent=2) + "\n")
print(json.dumps(sidecar, indent=2))
print("installed", (DST / "hey-alfie.onnx").stat().st_size, "bytes")
