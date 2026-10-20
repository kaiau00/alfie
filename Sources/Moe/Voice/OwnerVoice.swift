import FluidAudio
import Foundation

/// "Is that you?" — the owner's voice as a rolling centroid. VOICE-PLAN.md §4.5.
///
/// CAM++ (FluidAudio, already in the dependency) turns a turn's audio into
/// a 192-d embedding; the centroid is the mean of the owner's accepted
/// turns and the score is a cosine. Enrolment is passive: every turn that
/// opened a session ("Hey Moe", or the held key) is the owner's unless a
/// centroid already exists and disagrees strongly — so the first days
/// build it and a guest saying the name later does not pollute it. A
/// Settings enrolment with read prompts (Phase 6) seeds it faster.
///
/// A soft signal by default (`Addressee`), never a gate on its own; the
/// lab's sub-1% error rates become several percent on a laptop mic across
/// a room. Stored in ~/.moe/voice/owner-voice.json.
actor OwnerVoice {

    struct Store: Codable {
        var centroid: [Float]
        var count: Int
        var updated: Date
    }

    static let file = Config.homeDir
        .appendingPathComponent("voice", isDirectory: true)
        .appendingPathComponent("owner-voice.json")
    /// A passive update only above this score once the centroid stands;
    /// below it the voice may be someone else's.
    static let passiveUpdateAbove: Float = 0.55
    /// Enrolments before the centroid is trusted at all.
    static let seedCount = 3
    static let minSeconds = 1.0

    private var embedder: CampPlusEmbedder?
    private var store: Store?

    var isLoaded: Bool { embedder != nil }
    /// What is on disk, whether or not the model has loaded. Settings asks
    /// this before anything else has run.
    var storedTurns: Int {
        if let store { return store.count }
        guard let data = try? Data(contentsOf: Self.file),
              let s = try? JSONDecoder().decode(Store.self, from: data) else { return 0 }
        return s.count
    }
    var isEnrolled: Bool { (store?.count ?? 0) >= Self.seedCount }
    var enrolledTurns: Int { store?.count ?? 0 }

    /// Load the model (a download the first time) and the stored centroid.
    func load() async throws {
        if let data = try? Data(contentsOf: Self.file),
           let s = try? JSONDecoder().decode(Store.self, from: data),
           s.centroid.count == CampPlusEmbedder.embeddingDim {
            store = s
        }
        guard embedder == nil else { return }
        embedder = try await CampPlusEmbedder.load()
        Log.write("owner voice: model loaded, \(store?.count ?? 0) enrolled turns")
    }

    /// Cosine similarity of `audio16k` to the owner, or nil without an
    /// enrolment worth the name.
    func score(_ audio16k: [Float]) async -> Float? {
        guard let embedder, let store, store.count >= Self.seedCount,
              audio16k.count >= Int(Self.minSeconds * 16_000) else { return nil }
        guard let e = try? await embedder.embed(audio: audio16k) else { return nil }
        return Self.cosine(e, store.centroid)
    }

    /// The embedding on its own, for comparing one turn against *another
    /// turn* rather than against the stored centroid. VOICE-ISOLATION.md §2:
    /// the utterance that opens a session is a free enrolment sample of
    /// exactly the voice that owns the next thirty seconds — this
    /// microphone, this room, this distance, seconds ago — and is a better
    /// reference for the rest of that conversation than the owner in
    /// general. It needs no enrolment, and it is right about a guest.
    func embedding(_ audio16k: [Float]) async -> [Float]? {
        guard let embedder, audio16k.count >= Int(Self.minSeconds * 16_000) else { return nil }
        return try? await embedder.embed(audio: audio16k)
    }

    /// Fold a turn into the centroid. `known`: the turn is the owner's by
    /// construction (an enrolment prompt). Otherwise it must be close to
    /// what is already known, or be among the first few.
    @discardableResult
    func enrol(_ audio16k: [Float], known: Bool = false) async -> Float? {
        guard let embedder, audio16k.count >= Int(Self.minSeconds * 16_000) else { return nil }
        guard let e = try? await embedder.embed(audio: audio16k) else { return nil }
        var s = store ?? Store(centroid: [Float](repeating: 0, count: e.count), count: 0, updated: Date())
        let similarity = s.count > 0 ? Self.cosine(e, s.centroid) : 1
        if !known, s.count >= Self.seedCount, similarity < Self.passiveUpdateAbove {
            Log.write("owner voice: turn not folded in (similarity \(String(format: "%.2f", similarity)))")
            return similarity
        }
        // Capped: a centroid of five hundred turns stops following a
        // new microphone, a cold, a different room.
        let n = Float(min(s.count, 50))
        for i in 0..<e.count { s.centroid[i] = (s.centroid[i] * n + e[i]) / (n + 1) }
        s.centroid = Self.normalised(s.centroid)
        s.count += 1
        s.updated = Date()
        store = s
        save()
        return similarity
    }

    /// One embedding of silence so the first real turn does not pay the
    /// model's first-run compilation (about a second on this Mac).
    func warmUp() async {
        guard let embedder else { return }
        _ = try? await embedder.embed(audio: [Float](repeating: 0, count: 16_000))
    }

    func forget() {
        store = nil
        try? FileManager.default.removeItem(at: Self.file)
    }

    private func save() {
        guard let store else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: Self.file, options: .atomic) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / max(sqrt(na) * sqrt(nb), 1e-9)
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let n = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return v.map { $0 / n }
    }
}
