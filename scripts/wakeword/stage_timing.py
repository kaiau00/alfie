import time, numpy as np, onnxruntime as ort
here = "/path/to/wake/"
so = ort.SessionOptions(); so.intra_op_num_threads = 1
mel = ort.InferenceSession(here + "melspectrogram.onnx", so, providers=["CPUExecutionProvider"])
emb = ort.InferenceSession(here + "embedding_model.onnx", so, providers=["CPUExecutionProvider"])
head = ort.InferenceSession(here + "hey_livekit.onnx", so, providers=["CPUExecutionProvider"])
x = np.fromfile(here + "positive_full.f32", dtype=np.float32)[None, :]
def t(f, n=50):
    f(); s = time.perf_counter()
    for _ in range(n): f()
    return (time.perf_counter() - s) / n * 1000
m = mel.run(None, {"input": x})[0]
print("mel frames", m.shape, "%.2f ms" % t(lambda: mel.run(None, {"input": x})))
m = m[0, 0] / 10 + 2
F = m.shape[0]
wc = (F - 76) // 8 + 1
batch = np.stack([m[(wc - 16 + b) * 8:(wc - 16 + b) * 8 + 76] for b in range(16)])[..., None].astype(np.float32)
print("embed x16 %.2f ms" % t(lambda: emb.run(None, {"input_1": batch})))
one = batch[:1]
print("embed x1  %.2f ms" % t(lambda: emb.run(None, {"input_1": one})))
e = emb.run(None, {"input_1": batch})[0].reshape(1, 16, 96)
print("head      %.2f ms" % t(lambda: head.run(None, {"embeddings": e})))
# Incremental check: shifting the audio by exactly 1280 samples shifts the
# mel grid by exactly 8 frames?
x2 = np.concatenate([x[:, 1280:], np.zeros((1, 1280), np.float32)], axis=1)
m2 = mel.run(None, {"input": x2})[0][0, 0] / 10 + 2
print("shift-invariance max diff over overlap:", float(np.abs(m2[:F - 8] - m[8:]).max()))
