"""Are the mel front end's initialisers reproducible from public formulas?"""
import numpy as np, onnx
from onnx import numpy_helper
import librosa
import sys
# usage: <reference melspectrogram.onnx dir>/ (with positive_full.f32, negative_full.f32 beside it)
here = sys.argv[1].rstrip("/") + "/"
m = onnx.load(here + "melspectrogram.onnx")
init = {t.name: numpy_helper.to_array(t) for t in m.graph.initializer}
real = init["0.stft.conv_real.weight"][:, 0, :]   # [257, 512]
imag = init["0.stft.conv_imag.weight"][:, 0, :]
melW = init["1.melW"]                               # [257, 32]
for k in ("onnx::Clip_39", "onnx::Clip_40", "onnx::Clip_41"):
    print(k, init[k])
consts = {n.name: numpy_helper.to_array(n.attribute[0].t) for n in m.graph.node if n.op_type == "Constant"}
for k, v in consts.items():
    if v.dtype == np.float32: print(k, v)

N = 512
# torchlibrosa: window (win_length, centered/padded to n_fft), kernels
# cos(2π k n/N) * w[n] and -sin(...) * w[n].
n = np.arange(N)
best = None
for win_len in (400, 512):
    for periodic in (True, False):
        w = librosa.filters.get_window("hann", win_len, fftbins=periodic)
        w = librosa.util.pad_center(w, size=N)
        k = np.arange(N // 2 + 1)[:, None]
        cr = np.cos(2 * np.pi * k * n[None, :] / N) * w[None, :]
        ci = -np.sin(2 * np.pi * k * n[None, :] / N) * w[None, :]
        dr = np.abs(cr - real).max(); di = np.abs(ci - imag).max()
        print(f"win {win_len} periodic={periodic}: real diff {dr:.2e} imag diff {di:.2e}")
for htk in (False, True):
    for norm in (None, "slaney"):
        fb = librosa.filters.mel(sr=16000, n_fft=N, n_mels=32, fmin=60, fmax=3800, htk=htk, norm=norm).T
        print(f"mel htk={htk} norm={norm}: diff {np.abs(fb - melW).max():.2e}")
