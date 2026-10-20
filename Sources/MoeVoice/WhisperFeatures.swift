import Accelerate
import Foundation

/// The 80-band log-mel spectrogram Whisper-family models eat, exactly as
/// Pipecat's `_whisper_features.py` computes it for Smart Turn v3
/// (VOICE-PLAN.md §4.2): 16 kHz, 8 s window left-padded with zeros, whole-
/// buffer normalisation, n_fft 400 / hop 160, periodic Hann, reflect
/// centring, Slaney mel filters with Slaney area normalisation, log10,
/// clamp to max − 8, then (x + 4) / 4. Output `[80][800]`, row-major.
///
/// Every number here is the reference's. The one published Swift port used
/// n_fft 512 and no centring, which is a different model input.
public struct WhisperFeatures: Sendable {

    public static let sampleRate = 16_000
    public static let seconds = 8
    public static let samples = sampleRate * seconds       // 128 000
    public static let nFFT = 400
    public static let hop = 160
    public static let bins = nFFT / 2 + 1                  // 201
    public static let mels = 80
    public static let frames = samples / hop               // 800 kept of 801
    private static let pad = nFFT / 2                      // 200, reflect

    // Precomputed tables: window, DFT cos/sin [nFFT × bins], mel filters
    // [bins × mels]. Built once; the matrices make the whole spectrogram
    // two `sgemm` calls.
    private let window: [Float]
    private let cosTable: [Float]     // nFFT × bins
    private let sinTable: [Float]     // nFFT × bins
    private let melFilters: [Float]   // bins × mels

    public init() {
        let n = Self.nFFT, b = Self.bins
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(n)) }
        var c = [Float](repeating: 0, count: n * b)
        var s = [Float](repeating: 0, count: n * b)
        for k in 0..<n {
            for f in 0..<b {
                let angle = -2.0 * Double.pi * Double(k) * Double(f) / Double(n)
                c[k * b + f] = Float(cos(angle))
                s[k * b + f] = Float(sin(angle))
            }
        }
        cosTable = c
        sinTable = s
        melFilters = Self.slaneyFilterBank()
    }

    /// Features for the last 8 s of `audio` (16 kHz mono), left-padded with
    /// silence when shorter. `[80 * 800]` floats, mel-major.
    public func features(for audio: [Float]) -> [Float] {
        // 1. The last 8 s, zeros in front.
        var x = [Float](repeating: 0, count: Self.samples)
        let take = min(audio.count, Self.samples)
        if take > 0 {
            x.replaceSubrange((Self.samples - take)..<Self.samples, with: audio.suffix(take))
        }

        // 2. Whole-buffer normalisation, zeros included (float32, as the
        //    reference does it).
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(x.count))
        var sumsq: Float = 0
        vDSP_svesq(x, 1, &sumsq, vDSP_Length(x.count))
        let variance = sumsq / Float(x.count)
        var scale = 1 / (variance + 1e-7).squareRoot()
        vDSP_vsmul(x, 1, &scale, &x, 1, vDSP_Length(x.count))

        // 3. Reflect-centre by nFFT/2 on both ends.
        let p = Self.pad
        var padded = [Float](repeating: 0, count: x.count + 2 * p)
        for i in 0..<p { padded[i] = x[p - i] }
        padded.replaceSubrange(p..<(p + x.count), with: x)
        for i in 0..<p { padded[p + x.count + i] = x[x.count - 2 - i] }

        // 4. Windowed frames [801 × 400] → real/imag [801 × 201] by matrix
        //    multiply against the DFT tables → power.
        let nf = Self.frames + 1, n = Self.nFFT, b = Self.bins
        var framesM = [Float](repeating: 0, count: nf * n)
        for f in 0..<nf {
            let start = f * Self.hop
            padded.withUnsafeBufferPointer { src in
                window.withUnsafeBufferPointer { w in
                    framesM.withUnsafeMutableBufferPointer { dst in
                        vDSP_vmul(src.baseAddress! + start, 1, w.baseAddress!, 1,
                                  dst.baseAddress! + f * n, 1, vDSP_Length(n))
                    }
                }
            }
        }
        var re = [Float](repeating: 0, count: nf * b)
        var im = [Float](repeating: 0, count: nf * b)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(nf), Int32(b), Int32(n),
                    1, framesM, Int32(n), cosTable, Int32(b), 0, &re, Int32(b))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(nf), Int32(b), Int32(n),
                    1, framesM, Int32(n), sinTable, Int32(b), 0, &im, Int32(b))
        var power = [Float](repeating: 0, count: nf * b)
        vDSP_vsq(re, 1, &power, 1, vDSP_Length(nf * b))
        var im2 = [Float](repeating: 0, count: nf * b)
        vDSP_vsq(im, 1, &im2, 1, vDSP_Length(nf * b))
        vDSP_vadd(power, 1, im2, 1, &power, 1, vDSP_Length(nf * b))

        // 5. Mel: [801 × 201] × [201 × 80] → [801 × 80]; floor 1e-10; log10.
        var mel = [Float](repeating: 0, count: nf * Self.mels)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(nf), Int32(Self.mels), Int32(b),
                    1, power, Int32(b), melFilters, Int32(Self.mels), 0, &mel, Int32(Self.mels))
        var floor: Float = 1e-10
        vDSP_vthr(mel, 1, &floor, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlog10f(&mel, mel, &count)

        // 6. Drop the last frame, transpose to [80 × 800], clamp, scale.
        let kept = Self.frames
        var out = [Float](repeating: 0, count: Self.mels * kept)
        var maxv: Float = -.greatestFiniteMagnitude
        for f in 0..<kept {
            for m in 0..<Self.mels {
                let v = mel[f * Self.mels + m]
                out[m * kept + f] = v
                if v > maxv { maxv = v }
            }
        }
        var lo = maxv - 8
        vDSP_vthr(out, 1, &lo, &out, 1, vDSP_Length(out.count))
        var four: Float = 4
        var quarter: Float = 0.25
        vDSP_vsadd(out, 1, &four, &out, 1, vDSP_Length(out.count))
        vDSP_vsmul(out, 1, &quarter, &out, 1, vDSP_Length(out.count))
        return out
    }

    // MARK: - Slaney mel filter bank (HF `mel_filter_bank`, norm "slaney")

    static func hertzToMel(_ f: Double) -> Double {
        let minLogHz = 1000.0, minLogMel = 15.0, logstep = log(6.4) / 27
        return f >= minLogHz ? minLogMel + log(f / minLogHz) / logstep : 3 * f / 200
    }

    static func melToHertz(_ m: Double) -> Double {
        let minLogHz = 1000.0, minLogMel = 15.0, logstep = log(6.4) / 27
        return m >= minLogMel ? minLogHz * exp(logstep * (m - minLogMel)) : 200 * m / 3
    }

    /// `[bins × mels]`, row-major.
    static func slaneyFilterBank() -> [Float] {
        let b = bins, m = mels
        let fftFreqs = (0..<b).map { Double($0) * 8000 / Double(b - 1) }
        let melMin = hertzToMel(0), melMax = hertzToMel(8000)
        let melFreqs = (0..<(m + 2)).map { melMin + (melMax - melMin) * Double($0) / Double(m + 1) }
        let filterFreqs = melFreqs.map(melToHertz)
        var out = [Float](repeating: 0, count: b * m)
        for j in 0..<m {
            let lower = filterFreqs[j], centre = filterFreqs[j + 1], upper = filterFreqs[j + 2]
            let enorm = 2.0 / (upper - lower)
            for i in 0..<b {
                let f = fftFreqs[i]
                let down = (f - lower) / (centre - lower)
                let up = (upper - f) / (upper - centre)
                let w = max(0, min(down, up))
                out[i * m + j] = Float(w * enorm)
            }
        }
        return out
    }
}
