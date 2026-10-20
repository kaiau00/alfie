import Foundation

/// Who rewrites a dictation, in the order they are tried.
///
/// Pure Foundation and in MoeDictation on purpose: the *ordering* is the
/// portable decision, and it should be testable without a model, a server or
/// a network. The backends that implement each tier live in the app target
/// because they need Apple's framework, Hermes, or both.
///
/// Ordered by what the user experiences — speed and privacy first, capability
/// last — rather than by how impressive the model is. A dictation rewrite is
/// mechanical: a 3B model on the Neural Engine does it as well as a frontier
/// model and several times faster. Measured over 29 real dictations on the
/// old single-tier path: speech engines 307 ms, rewrite 3604 ms, which is 92%
/// of the wait, and the rewrite was a `claude` child process asked to fix
/// punctuation on thirty words.
///
/// Both mature open-source dictation tools reached this independently, and
/// neither uses a cloud API for it: OpenWhispr runs a local GGUF model
/// through llama.cpp with thinking disabled; Handy calls Apple's on-device
/// model. A polish is a small, local, thinking-off job.
public enum PolishTier: String, CaseIterable, Codable, Sendable {
    /// Apple's on-device model (`FoundationModels`, macOS 26 + Apple
    /// Intelligence). No key, no download we manage, no cost, and the
    /// transcript never leaves the Mac.
    case appleOnDevice

    /// A local model server — Ollama or LM Studio — through Hermes, which
    /// already speaks both. The tier that makes Windows and Linux fast
    /// (CROSS-PLATFORM.md), and the only on-device option on a Mac without
    /// Apple Intelligence.
    case localServer

    /// Whatever brain the conversation uses. Always works, always slowest,
    /// and the only tier that sends the transcript off the machine.
    case configuredBrain

    /// No model at all: `TranscriptCleaner`'s rules, which have already run.
    /// Instant, offline, and the floor nothing falls below.
    case rulesOnly

    /// What Settings shows. Never an engine name — the same discipline
    /// `SttBackend.displayName` keeps, so the user chooses an outcome.
    public var displayName: String {
        switch self {
        case .appleOnDevice:   return "On this Mac (fastest, private)"
        case .localServer:     return "A model running on this computer"
        case .configuredBrain: return "Your AI (most capable, slowest)"
        case .rulesOnly:       return "Rules only (instant, offline)"
        }
    }

    /// True when nothing leaves this machine. Drives the Settings copy, which
    /// must never overstate privacy — hence a fact here rather than a
    /// sentence written twice.
    public var isOnDevice: Bool { self != .configuredBrain }

    /// The order to try, for a given preference.
    ///
    /// A preference is moved to the front rather than made exclusive: picking
    /// the fastest tier on a machine that later loses it must not silently
    /// disable the rewrite. `rulesOnly` is the exception — it means "no
    /// model, ever", which is a privacy choice and is honoured absolutely.
    public static func ladder(preferred: PolishTier?) -> [PolishTier] {
        if preferred == .rulesOnly { return [] }
        var order: [PolishTier] = [.appleOnDevice, .localServer, .configuredBrain]
        if let preferred, let i = order.firstIndex(of: preferred) {
            order.remove(at: i)
            order.insert(preferred, at: 0)
        }
        return order
    }
}
