import Foundation

/// The terms harvested from the screen for the dictation currently in
/// flight. Set when the key goes down, read while the utterance is being
/// transcribed and rewritten, cleared when it is done.
///
/// A box rather than a parameter because the two readers are a long way
/// apart — the speech router deep inside `VoiceEngine` and the polish prompt
/// up in `Conductor` — and threading a per-utterance list through every
/// engine, backend and initialiser between them would put the ephemeral
/// vocabulary into the signature of code that has no business knowing it
/// exists.
///
/// **It is never written to disk, and it must never be.** `Vocabulary` is the
/// standing list the user owns and can edit; this is a guess about one
/// sentence, made from whatever happened to be on screen. The moment a guess
/// like that is persisted it stops being a guess and starts being a rule —
/// which is exactly how a vocabulary file full of project jargon came to be
/// rewriting ordinary speech. Keeping the two in different types, with only
/// this one holding no URL and offering no way to save, is the guardrail.
public final class LiveVocabulary: @unchecked Sendable {

    public static let shared = LiveVocabulary()

    private let lock = NSLock()
    private var terms: [String] = []

    public init() {}

    /// Replace the terms for the utterance about to start. A dictation that
    /// harvests nothing calls this with an empty list rather than skipping
    /// it, so the previous utterance's screen never leaks into this one.
    public func set(_ terms: [String]) {
        lock.lock(); defer { lock.unlock() }
        self.terms = terms
    }

    public func current() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return terms
    }

    public func clear() { set([]) }

    /// `base` (the user's own vocabulary) first, then whatever screen terms
    /// it does not already contain. The user's file always wins: a spelling
    /// somebody typed out on purpose outranks one Moe read off a window, and
    /// order is what decides that — every consumer downstream truncates from
    /// the end.
    ///
    /// Static and pure so it can be tested without touching `shared`.
    public static func merge(_ base: [String], _ live: [String]) -> [String] {
        guard !live.isEmpty else { return base }
        var seen = Set(base.map { $0.lowercased() })
        return base + live.filter { seen.insert($0.lowercased()).inserted }
    }
}
