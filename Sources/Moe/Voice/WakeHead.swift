import Foundation
import MoeVoice
import OnnxRuntimeBindings

/// "Hey Moe", as a model. VOICE-PLAN.md §4.1.
///
/// The LiveKit WakeWord design (Apache-2.0): a frozen mel front end and a
/// frozen speech-embedding backbone (openWakeWord's, Google's
/// speech_embedding), then a small classifier trained on this phrase. All
/// three run through onnxruntime on the CPU with one thread; a score for
/// a two-second window costs a few milliseconds on an M-series Mac, and
/// the pipeline only asks while the VAD hears speech.
///
/// Stateless: every call scores the whole window it is given, exactly as
/// the head was trained and as LiveKit's own runtime does — the positives
/// are end-aligned, so the phrase must have just finished inside it.
///
/// The three files ship in the app bundle (`Resources/WakeWord`); nothing
/// is downloaded. The classifier's sidecar JSON carries the threshold the
/// training run found, so a retrained head never needs a code change.
actor WakeHead {

    /// `hey-alfie.json` beside the classifier: what the training run found
    /// and what the bench settled on. Every field optional.
    struct Metadata: Decodable {
        var threshold: Float?
        /// A single window this sure is a detection on its own.
        var strong: Float?
        /// Consecutive windows over `threshold` that make a detection.
        var hits: Int?
        var phrases: [String]?
        var trained: String?
    }

    /// How scores become detections: the sidecar's policy, at this Mac's
    /// threshold when Settings has measured one (`WakeTuning`).
    private(set) var policy = WakePolicy()
    /// The sidecar's policy as shipped, which every per-Mac threshold is
    /// built from and which "Forget my recordings" goes back to.
    private(set) var shippedPolicy = WakePolicy()

    static let sampleRate = 16_000
    /// What one score looks at: 32 000 samples → ~200 mel frames → 16
    /// embedding windows, the classifier's whole input.
    static let windowSamples = 32_000
    /// How often to score: one embedding stride (8 mel frames of 10 ms).
    static let strideSamples = 1_280

    private static let melWindow = 76
    private static let melStride = 8
    private static let melBins = 32
    private static let embeddings = 16
    private static let embeddingDim = 96

    private var env: ORTEnv?
    private var mel: ORTSession?
    private var embed: ORTSession?
    private var head: ORTSession?
    private(set) var threshold: Float = 0.5
    private(set) var phrases: [String] = []
    /// The sidecar's `trained` stamp: which head this is, for `WakeTuning`.
    private(set) var identity: String?

    /// The `trained` stamp of the head `locate()` finds, without loading
    /// it — what a per-Mac threshold on disk is checked against.
    static func shippedIdentity() -> String? {
        guard let dir = locate(),
              let data = try? Data(contentsOf: dir.appendingPathComponent("hey-alfie.json")),
              let meta = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
        return meta.trained
    }

    var isLoaded: Bool { head != nil }

    enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self { case .missing(let what): return "wake word file not found: \(what)" }
        }
    }

    /// Where the three files live: the app bundle, or the repo when run
    /// from `.build` during development.
    static func locate() -> URL? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("WakeWord")) }
        // Development: `.build/debug/Moe` or `.build/arm64-apple-macosx/debug/Moe`
        // — walk up to the checkout.
        var dir = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Resources/WakeWord"))
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(Config.homeDir.appendingPathComponent("models/wakeword"))
        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("hey-alfie.onnx").path) }
    }

    func load(from dir: URL? = nil) throws {
        guard head == nil else { return }
        guard let dir = dir ?? Self.locate() else { throw LoadError.missing("Resources/WakeWord/hey-alfie.onnx") }
        let env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(1)
        try opts.setGraphOptimizationLevel(.all)
        func open(_ name: String) throws -> ORTSession {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.missing(name) }
            return try ORTSession(env: env, modelPath: url.path, sessionOptions: opts)
        }
        let mel = try open("melspectrogram.onnx")
        let embed = try open("embedding_model.onnx")
        let head = try open("hey-alfie.onnx")
        let sidecar = dir.appendingPathComponent("hey-alfie.json")
        if let data = try? Data(contentsOf: sidecar) {
            do {
                let meta = try JSONDecoder().decode(Metadata.self, from: data)
                if let t = meta.threshold, t > 0, t < 1 { threshold = t }
                phrases = meta.phrases ?? []
                identity = meta.trained
                // `strong` ≥ 1 means never on one window; ≤ threshold is
                // ignored by the policy. `hits` beyond ten is a typo.
                policy = WakePolicy(threshold: threshold,
                                    strongThreshold: meta.strong.flatMap { $0 > 0 ? $0 : nil },
                                    requiredHits: min(max(meta.hits ?? 2, 1), 10))
            } catch {
                Log.write("wake head: sidecar unreadable (\(error)); defaults")
                policy = WakePolicy(threshold: threshold)
            }
        } else {
            policy = WakePolicy(threshold: threshold)
        }
        shippedPolicy = policy
        self.env = env
        self.mel = mel
        self.embed = embed
        self.head = head
        // This Mac's own number, when the person has taught Moe its name.
        // Applied after the sidecar so a retrained head keeps its `strong`
        // and run length, and the person keeps their threshold.
        var yours = ""
        // Only a number measured on this same head (`WakeTuning.head`).
        if let tuning = WakeTuning.load(for: identity) {
            setThreshold(tuning.threshold)
            yours = ", yours"
        }
        Log.write("wake head: loaded from \(dir.path) (threshold \(threshold)\(yours))")
    }

    /// Use this threshold from now on, or nil for the sidecar's. The
    /// pipeline holds its own copy of the policy: whoever calls this
    /// re-attaches it (`VoiceEngine.applyWakePolicy`).
    func setThreshold(_ t: Float?) {
        if let t, t > 0, t < 1 {
            policy = shippedPolicy.withThreshold(t)
            threshold = t
        } else {
            policy = shippedPolicy
            threshold = shippedPolicy.threshold
        }
    }

    /// The last 16 embeddings, oldest first — valid for a window exactly
    /// one stride after the one that produced them.
    private var ring: [Float] = []
    /// The mel frames of the previous window, for the overlap check.
    private var lastFrames: [Float] = []

    /// One run of the mel front end, scaled the way openWakeWord scales it:
    /// `[1, N]` samples in, a flat `frames * melBins` array out.
    ///
    /// The one place the model is called, so `score` and the tests that
    /// characterise it cannot end up measuring two different things — a
    /// test that agrees with the code because both invented the same number
    /// is the mistake this repo keeps finding.
    func melFrames(of pcm: [Float]) throws -> [Float] {
        guard let mel else { return [] }
        var buf = pcm
        let data = NSMutableData(bytes: &buf, length: buf.count * MemoryLayout<Float>.size)
        let value = try ORTValue(tensorData: data, elementType: .float,
                                 shape: [1, NSNumber(value: buf.count)])
        let out = try mel.run(withInputs: ["input": value], outputNames: ["output"], runOptions: nil)
        guard let tensor = out["output"] else { return [] }
        var f: [Float] = try withExtendedLifetime(out) {
            let bytes = try tensor.tensorData() as Data
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        for i in f.indices { f[i] = f[i] / 10 + 2 }
        return f
    }

    /// Probability that the phrase just ended inside `window` (16 kHz
    /// mono, ideally `windowSamples` long; at least one second).
    ///
    /// `contiguous`: this window is the previous one shifted by exactly
    /// `strideSamples`. The mel front end has no padding, so its frames
    /// then shift by exactly one embedding stride and fifteen of the
    /// sixteen embeddings are the ones already computed; only the newest
    /// window goes through the backbone. Same numbers as the full run
    /// (checked to 1e-7 by `Moe --wake-slide`), a fifth of the cost.
    func score(_ window: [Float], contiguous: Bool = false) throws -> Float {
        guard mel != nil, let embed, let head else { return 0 }
        guard window.count >= Self.sampleRate else { return 0 }
        let audio = window.count > 48_000 ? Array(window.prefix(48_000)) : window   // as the reference

        // 1. Mel: [1, N] → [1, 1, F, 32], then openWakeWord's scaling.
        //
        //    **The whole window, every stride, and it is deliberate.** This
        //    is the most expensive thing "Hey Moe" does — 97.8% of what
        //    always-listening costs, measured by putting 452 s of speech and
        //    452 s of silence through `--wake-bench`: 57.4 s of CPU against
        //    1.3 s, because the VAD gates this off in silence. Two seconds
        //    of audio go through the model to obtain the eight new frames a
        //    stride needs, which is eighteen times more work than
        //    openWakeWord's own runtime does; its `AudioFeatures` streams
        //    `n_samples + 160*3` = 1 760 samples and appends to a rolling
        //    buffer. Doing the same here is worth 10.8 ms → 4.1 ms a score.
        //
        //    **It is also wrong, and wrong rarely, which is worse.** This
        //    model ends in a `top_db` clamp: every value below
        //    `max(input) − 80` is raised to that floor, and the maximum is
        //    taken over the whole tensor it was handed. Measured — every
        //    full window spans exactly 80.000 dB whatever is in it. So a
        //    110 ms chunk clamps at its own floor, not the window's. Most of
        //    the time the window's loudest moment is inside the chunk and
        //    nothing moves; at 2 positions in 40 it does, and quiet bins
        //    land up to 3.0 apart, beside a per-frame float difference of
        //    7.6e-06.
        //
        //    It cost a detection on the owner's own recordings: recall
        //    40/65 → 39/65, one file's peak falling 0.67 → 0.48 across the
        //    0.5 threshold, false accepts unchanged. The other 64 were
        //    fine, which is the shape of a bug that ships. `--wake-slide`
        //    catches it (max |incremental − full| went 0.0 → 0.005) and it
        //    is worth running before believing otherwise.
        //
        //    A bounded version is still available and is the right next
        //    step, alongside a retrain rather than before one: a chunk is a
        //    subset of its window, so its maximum can only be lower and its
        //    floor can only be lower, and `max(chunkFrame, windowMax − 80)`
        //    recovers the window's value exactly — as long as the window's
        //    running maximum is carried with the frame buffer, and frames
        //    the *previous* window had already clamped are accounted for.
        let frames = try melFrames(of: audio)
        let frameCount = frames.count / Self.melBins

        // 2. The last 16 of the 76-frame windows at stride 8, from frame 0
        //    — the same grid as training and the reference runtime.
        guard frameCount >= Self.melWindow else { return 0 }
        let windowCount = (frameCount - Self.melWindow) / Self.melStride + 1
        guard windowCount >= Self.embeddings else { return 0 }
        let perWindow = Self.melWindow * Self.melBins
        let ringSize = Self.embeddings * Self.embeddingDim
        // The front end scales every window to its own loudest bin, so
        // the frames shared with the previous window are only the same
        // numbers while that peak is the same. Check rather than assume:
        // the overlap must match the previous frames shifted by one
        // stride, else the embeddings are recomputed in full.
        let shift = Self.melStride * Self.melBins
        var overlapMatches = false
        if contiguous, ring.count == ringSize, lastFrames.count == frames.count, frames.count > shift {
            overlapMatches = true
            var i = 0
            let n = frames.count - shift
            while i < n {
                if abs(frames[i] - lastFrames[i + shift]) > 1e-5 { overlapMatches = false; break }
                i += 1
            }
        }
        lastFrames = frames
        do {
        if overlapMatches {
            let start = (windowCount - 1) * Self.melStride * Self.melBins
            let newest = try embeddings(of: Array(frames[start ..< start + perWindow]), count: 1, with: embed)
            guard newest.count == Self.embeddingDim else { ring.removeAll(); return 0 }
            ring.removeFirst(Self.embeddingDim)
            ring.append(contentsOf: newest)
        } else {
            let firstWindow = windowCount - Self.embeddings
            var batch = [Float](repeating: 0, count: Self.embeddings * perWindow)
            for b in 0..<Self.embeddings {
                let start = (firstWindow + b) * Self.melStride * Self.melBins
                batch.replaceSubrange(b * perWindow ..< (b + 1) * perWindow, with: frames[start ..< start + perWindow])
            }
            let all = try embeddings(of: batch, count: Self.embeddings, with: embed)
            guard all.count == ringSize else { ring.removeAll(); return 0 }
            ring = all
        }
        } catch {
            // Half-updated state would shift a stale ring next time.
            forget()
            throw error
        }
        var emb = ring

        // 3. The head: [1, 16, 96] → [1, 1].
        let embData = NSMutableData(bytes: &emb, length: emb.count * MemoryLayout<Float>.size)
        let embInput = try ORTValue(tensorData: embData, elementType: .float,
                                    shape: [1, NSNumber(value: Self.embeddings), NSNumber(value: Self.embeddingDim)])
        let out = try head.run(withInputs: ["embeddings": embInput], outputNames: ["score"], runOptions: nil)
        guard let scoreValue = out["score"] else { return 0 }
        return try withExtendedLifetime(out) {
            let bytes = try scoreValue.tensorData() as Data
            guard bytes.count >= MemoryLayout<Float>.size else { return 0 }
            return bytes.withUnsafeBytes { $0.load(as: Float.self) }
        }
    }

    /// Forget the incremental state: the next score is a full run.
    func forget() { ring.removeAll(); lastFrames.removeAll() }

    /// `count` mel windows of 76 × 32 → `count` × 96.
    private func embeddings(of windows: [Float], count: Int, with embed: ORTSession) throws -> [Float] {
        var input = windows
        let data = NSMutableData(bytes: &input, length: input.count * MemoryLayout<Float>.size)
        let value = try ORTValue(tensorData: data, elementType: .float,
                                 shape: [NSNumber(value: count), NSNumber(value: Self.melWindow),
                                         NSNumber(value: Self.melBins), 1])
        let out = try embed.run(withInputs: ["input_1": value], outputNames: ["conv2d_19"], runOptions: nil)
        guard let result = out["conv2d_19"] else { return [] }
        return try withExtendedLifetime(out) {
            let bytes = try result.tensorData() as Data
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }
}
