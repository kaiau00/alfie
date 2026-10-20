"""The 80-band log-mel Smart Turn eats, in numpy, for the bench.

A second implementation of what `Sources/MoeVoice/WhisperFeatures.swift`
does. It exists so `scripts/bench-turn-model.sh` can vary one thing at a time
against the real ONNX model without building the app. It is NOT the app's
path: the Swift one is, and that is pinned to reference fixtures by
`WhisperFeaturesTests`. Because the bench only ever compares one run against
another through this same code, an error in it cancels out.

Left-padding — zeros first, the speech flush against the end of the window —
is what both do, and it was checked rather than assumed. Pipecat's reference
hands the clip to HuggingFace's WhisperFeatureExtractor with
padding="max_length", which reads like a right pad, so the model was asked:

    full sentence   cut off mid-phrase   separation
    left  0.620                  0.205       +0.415
    right 0.746                  0.912       -0.166   (inverted)

Right-padding calls 58 of 60 truncated clips finished. Left is correct.
"""
import sys, glob
import numpy as np, soundfile as sf, onnxruntime as ort

SR, NFFT, HOP, NMEL, SECS = 16000, 400, 160, 80, 8
N = SR * SECS

def hz_to_mel_slaney(f):
    f = np.asarray(f, dtype=float)
    m = 3.0 * f / 200.0
    log_t, min_log_hz, logstep = 15.0, 1000.0, np.log(6.4) / 27.0
    hi = f >= min_log_hz
    m[hi] = log_t + np.log(f[hi] / min_log_hz) / logstep
    return m

def mel_to_hz_slaney(m):
    m = np.asarray(m, dtype=float)
    f = 200.0 * m / 3.0
    log_t, min_log_hz, logstep = 15.0, 1000.0, np.log(6.4) / 27.0
    hi = m >= log_t
    f[hi] = min_log_hz * np.exp(logstep * (m[hi] - log_t))
    return f

def mel_filters():
    bins = NFFT // 2 + 1
    fft_freqs = np.linspace(0, SR / 2, bins)
    pts = mel_to_hz_slaney(np.linspace(hz_to_mel_slaney(np.array([0.0]))[0],
                                       hz_to_mel_slaney(np.array([SR / 2.0]))[0], NMEL + 2))
    fb = np.zeros((NMEL, bins))
    d = np.diff(pts)
    ramps = pts.reshape(-1, 1) - fft_freqs.reshape(1, -1)
    for i in range(NMEL):
        lo, hi = -ramps[i] / d[i], ramps[i + 2] / d[i + 1]
        fb[i] = np.maximum(0, np.minimum(lo, hi))
    fb *= (2.0 / (pts[2:NMEL + 2] - pts[:NMEL])).reshape(-1, 1)   # slaney norm
    return fb

FB = mel_filters()
WIN = np.hanning(NFFT + 1)[:-1]     # periodic

def features(x):
    """x: exactly N samples, already padded. Returns (1, 80, 800) float32."""
    x = (x - x.mean()) / np.sqrt(x.var() + 1e-7)
    p = NFFT // 2
    xp = np.pad(x, (p, p), mode="reflect")
    frames = np.lib.stride_tricks.sliding_window_view(xp, NFFT)[::HOP]
    spec = np.fft.rfft(frames * WIN, axis=-1)
    power = (spec.real ** 2 + spec.imag ** 2).T          # bins x frames
    mel = FB @ power
    log = np.log10(np.clip(mel, 1e-10, None))
    log = np.maximum(log, log.max() - 8.0)
    log = (log + 4.0) / 4.0
    return log[:, :-1][None].astype(np.float32)

def left_pad(a):                      # Moe today: zeros first, speech at end
    out = np.zeros(N, dtype=np.float32); out[N - len(a):] = a[-N:]; return out

def right_pad(a):                     # the reference: speech first, zeros after
    out = np.zeros(N, dtype=np.float32); out[:len(a)] = a[-N:][:N]; return out

