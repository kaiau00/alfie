import Foundation

/// What the person reads when a turn ends badly.
///
/// `HermesBrain` used to show the brain's own error text verbatim. On
/// 2026-09-15 that put this on the owner's island, twice in 74 seconds, in
/// the place Moe's reply goes:
///
///     another turn is still running for session 1e495ecf-d44; try again
///
/// He had typed while Moe's post-turn review still held the conversation's
/// process (fixed in the fork: background work runs in its own lane), but the
/// *shape* of the failure outlives that fix and is not specific to it. Any
/// brain — Claude Code, Codex, a plain API key, a gateway of someone else's —
/// can return a sentence written for a developer, and whatever it returns is
/// what lands on the island. So the translation lives here, on Moe's side of
/// the wire, where it holds for every provider.
///
/// The raw line is never lost: `HermesBrain.finishTurn` writes it to the log.
enum TurnError {
    /// Hermes's words for a turn that could not start because another turn on
    /// the same session had not finished. Spelled as the fork spells them
    /// (`agent/claude_code_runtime.py`, `TurnInFlightError`).
    static let busyMarkers = [
        "another turn is still running",
        "is still being set up by another request",
    ]

    /// Moe could not say what went wrong, so it says that.
    static let generic = "Alfie couldn't finish that thought. Ask again."

    /// Someone waiting on Moe, told in words they can act on.
    static let busy = "Alfie was still finishing the last thing — ask again in a moment."

    /// The person's words for `message`, which is always safe to show.
    ///
    /// Ordinary human-facing text (a sign-in problem, a network line Moe
    /// wrote itself) passes through unchanged; a developer's string does not.
    static func personWords(_ message: String) -> String {
        if let limit = WorkLimit.personWords(forTurnError: message) { return limit }
        if busyMarkers.contains(where: { message.contains($0) }) { return busy }
        // A message that names an internal identifier was written for a log,
        // not for a person — and it is the exact shape that reached the
        // island. Match on the identifier, not on the sentence around it, so
        // the next such message is caught by the same rule.
        if namesASession(message) { return generic }
        // Anything falling through is the provider's own text, and Moe's own
        // route is one Hermes deliberately leaves unredacted
        // (`_GATEWAY_RAW_TEXT_PLATFORMS`, gateway/run.py:358 — see
        // `BrainTrouble.redacted`). A provider's 401 body quotes the key
        // back, so nothing reaches a screen with a credential still in it.
        return BrainTrouble.redacted(message)
    }

    /// The same, for a turn whose provider is known and whose brain may have
    /// said *why* it failed.
    ///
    /// The extra return is the whole point: a failure the person has to act
    /// on is not only said here, it is kept in Settings › Brain until it is
    /// fixed — because a chat message scrolls away and the next message just
    /// fails again with nothing on screen saying why. `BrainTrouble` decides
    /// which failures those are; this is only the seam.
    ///
    /// - Returns: what the person reads, and the trouble to keep (nil for a
    ///   failure that clears itself, or that Moe has no opinion about).
    static func personWords(_ message: String, provider: BrainProviderKind,
                            failureReason: String? = nil,
                            failureRetryable: Bool? = nil) -> (words: String, keep: BrainTrouble.Kind?) {
        // The work limit is the person's own setting and outranks everything
        // else: they chose 5 minutes, Moe stopped at 5 minutes, and that is
        // not their provider failing however the brain phrased it.
        if let limit = WorkLimit.personWords(forTurnError: message) { return (limit, nil) }
        switch BrainTrouble.verdict(reason: failureReason, retryable: failureRetryable,
                                    message: message, provider: provider) {
        case .hard(let kind, let words):  return (words, kind)
        case .temporary(let words):       return (words, nil)
        case .thisRequest(let words):     return (words, nil)
        case .unknown:                    return (personWords(message), nil)
        }
    }

    /// Whether `message` carries a session/process identifier: the word
    /// "session" followed by something that is not prose.
    static func namesASession(_ message: String) -> Bool {
        guard let range = message.range(of: "session ", options: .caseInsensitive) else { return false }
        let rest = message[range.upperBound...]
        let token = rest.prefix { !$0.isWhitespace }
        guard token.count >= 6 else { return false }
        // "session id" is prose; "1e495ecf-d44" is not. A token with a digit
        // or a hyphen in it is an identifier.
        return token.contains(where: { $0.isNumber || $0 == "-" })
    }
}
