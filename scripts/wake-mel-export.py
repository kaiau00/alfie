"""A clean-room mel front end for the wake head, built from the public
formulas the openWakeWord/LiveKit file implements (verified constant by
constant in mel_constants.py): STFT as a strided convolution with DFT
kernels under a periodic Hann window of 400 in a 512-point frame, hop 160,
power spectrum, a Slaney-normalised 32-band mel filterbank over 60–3800 Hz,
10·log10 with a 1e-10 floor, and an 80 dB dynamic-range clamp below the
window's peak. Same graph shape and same numbers; nothing copied."""
import numpy as np, onnx, onnxruntime as ort
from onnx import helper, TensorProto, numpy_helper
import librosa

import sys
# usage: <reference melspectrogram.onnx dir>/ (with positive_full.f32, negative_full.f32 beside it)
here = sys.argv[1].rstrip("/") + "/"
N, HOP, WIN, MELS, SR, FMIN, FMAX, TOP_DB = 512, 160, 400, 32, 16000, 60.0, 3800.0, 80.0

n = np.arange(N)
w = librosa.util.pad_center(librosa.filters.get_window("hann", WIN, fftbins=True), size=N)
k = np.arange(N // 2 + 1)[:, None]
real = (np.cos(2 * np.pi * k * n[None, :] / N) * w[None, :]).astype(np.float32)[:, None, :]
imag = (-np.sin(2 * np.pi * k * n[None, :] / N) * w[None, :]).astype(np.float32)[:, None, :]
melW = librosa.filters.mel(sr=SR, n_fft=N, n_mels=MELS, fmin=FMIN, fmax=FMAX, htk=False, norm="slaney").T.astype(np.float32)

def const(name, value, dtype=np.float32):
    return numpy_helper.from_array(np.asarray(value, dtype=dtype), name=name)

inits = [
    numpy_helper.from_array(real, "stft_real"), numpy_helper.from_array(imag, "stft_imag"),
    numpy_helper.from_array(melW, "mel_filterbank"),
    const("axes1", [1], np.int64), const("two", 2.0), const("floor", 1e-10), const("ten", 10.0),
    const("ln10", np.log(10.0)), const("top_db", TOP_DB),
]
nodes = [
    helper.make_node("Unsqueeze", ["input", "axes1"], ["x"]),                        # [B,1,S]
    helper.make_node("Conv", ["x", "stft_real"], ["re"], strides=[HOP], kernel_shape=[N], pads=[0, 0]),
    helper.make_node("Conv", ["x", "stft_imag"], ["im"], strides=[HOP], kernel_shape=[N], pads=[0, 0]),
    helper.make_node("Pow", ["re", "two"], ["re2"]),
    helper.make_node("Pow", ["im", "two"], ["im2"]),
    helper.make_node("Add", ["re2", "im2"], ["power"]),                               # [B,257,F]
    helper.make_node("Transpose", ["power"], ["powerT"], perm=[0, 2, 1]),             # [B,F,257]
    helper.make_node("MatMul", ["powerT", "mel_filterbank"], ["mel"]),               # [B,F,32]
    helper.make_node("Max", ["mel", "floor"], ["mel_floor"]),
    helper.make_node("Log", ["mel_floor"], ["ln"]),
    helper.make_node("Div", ["ln", "ln10"], ["log10"]),
    helper.make_node("Mul", ["log10", "ten"], ["db"]),
    helper.make_node("ReduceMax", ["db"], ["peak"], keepdims=0),
    helper.make_node("Sub", ["peak", "top_db"], ["low"]),
    helper.make_node("Max", ["db", "low"], ["db_clamped"]),
    helper.make_node("Unsqueeze", ["db_clamped", "axes1"], ["output"]),               # [B,1,F,32]
]
graph = helper.make_graph(nodes, "mel_frontend", [helper.make_tensor_value_info("input", TensorProto.FLOAT, ["batch", "samples"])],
                          [helper.make_tensor_value_info("output", TensorProto.FLOAT, ["batch", 1, "frames", MELS])], inits)
model = helper.make_model(graph, producer_name="moe-wake-frontend", opset_imports=[helper.make_opsetid("", 13)])
model.ir_version = 8
onnx.checker.check_model(model)
onnx.save(model, here + "melspectrogram-moe.onnx")

so = ort.SessionOptions(); so.intra_op_num_threads = 1
a = ort.InferenceSession(here + "melspectrogram.onnx", so, providers=["CPUExecutionProvider"])
b = ort.InferenceSession(here + "melspectrogram-moe.onnx", so, providers=["CPUExecutionProvider"])
rng = np.random.default_rng(0)
worst = 0.0
tests = [np.fromfile(here + "positive_full.f32", np.float32), np.fromfile(here + "negative_full.f32", np.float32),
         rng.standard_normal(32000).astype(np.float32) * 0.1, np.zeros(32000, np.float32), rng.standard_normal(20000).astype(np.float32)]
for x in tests:
    ya = a.run(None, {"input": x[None, :]})[0]; yb = b.run(None, {"input": x[None, :]})[0]
    assert ya.shape == yb.shape, (ya.shape, yb.shape)
    worst = max(worst, float(np.abs(ya - yb).max()))
print("shape", yb.shape, "max |ours − theirs| over 5 inputs:", worst)
