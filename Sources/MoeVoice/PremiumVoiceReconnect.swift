import Foundation

/// A failure that knows whether it is the network going away, for a type
/// this module cannot see — the app's `CloudVoiceUnavailable.offline` is the
/// edge not answering when the voice asked for a credential.
public protocol PremiumVoiceConnectionFailure: Error {
    var isConnectionDrop: Bool { get }
}

/// The premium voice lost its connection for a moment, and came back.
///
/// On 2026-09-24 at 19:50 this Mac's network dropped for about ten seconds
/// (a local filter proxy restarting, which it does about every quarter of an
/// hour). Every sentence after it was spoken in the local voice for a full
/// minute, and nothing said why: the person heard the voice change
/// mid-conversation and was left to guess.
///
/// This is the rule for what the person is told, kept apart from the audio
/// so it can be tested: a stretch of dropped connection is one *episode*;
/// the first failed sentence of an episode says so once, quietly, in the
/// conversation, and every later failed sentence of the same episode says
/// nothing. A cloud sentence that renders ends the episode — logged, never
/// announced; the voice coming back is its own explanation.
///
/// Three failures, three policies, and this type only decides the first:
/// - **connection** (`isConnectionDrop`): local for the sentence, the edge's
///   short backoff decides when to ask again, one notice per episode;
/// - **out of credits** (`PremiumVoiceSpent`): local for the rest of the
///   voice, its own notice, once;
/// - **anything else** (a malformed request, an auth refusal): local for the
///   sentence, nothing said, as before.
public struct PremiumVoiceReconnect: Sendable {

    public enum Failure: Equatable, Sendable {
        /// The network or the edge went away. `notice` is the line to show,
        /// on the first failure of an episode only.
        case connection(notice: String?)
        /// `PremiumVoiceSpent` — handled by its own rule.
        case outOfCredits
        /// Anything else: local for this sentence, nothing said.
        case other
    }

    /// What the person is told, once per episode. Plain words: what
    /// happened, what they are hearing, and that it is brief.
    public static let notice = "Connection dropped — using the Mac's voice for a moment"

    /// When the current episode's first sentence failed; nil when the
    /// premium voice is speaking normally.
    public private(set) var droppedAt: Date?
    /// Sentences of this episode spoken locally, for the recovery log line.
    public private(set) var sentencesLocal = 0

    public init() {}

    public var inEpisode: Bool { droppedAt != nil }

    /// Whether this failure is the connection rather than the account or
    /// the request.
    public static func isConnectionDrop(_ error: Error) -> Bool {
        if PremiumVoiceSpent.matches(error) { return false }
        if let typed = error as? PremiumVoiceConnectionFailure { return typed.isConnectionDrop }
        switch error {
        case InworldError.unreachable, InworldError.connectionLost: return true
        case InworldError.rejected: return false
        default: break
        }
        if error is URLError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain
    }

    /// A cloud sentence failed and is being spoken locally instead.
    public mutating func failed(_ error: Error, now: Date = Date()) -> Failure {
        if PremiumVoiceSpent.matches(error) { return .outOfCredits }
        guard Self.isConnectionDrop(error) else { return .other }
        sentencesLocal += 1
        if droppedAt != nil { return .connection(notice: nil) }
        droppedAt = now
        return .connection(notice: Self.notice)
    }

    /// A cloud sentence rendered. Ends the episode if one was open.
    /// - Returns: how long the premium voice was away, for the log; nil when
    ///   it never was.
    public mutating func succeeded(now: Date = Date()) -> TimeInterval? {
        guard let since = droppedAt else { return nil }
        droppedAt = nil
        sentencesLocal = 0
        return max(0, now.timeIntervalSince(since))
    }

    /// The voice was changed or reloaded: whatever was happening to the
    /// old one is not news about the new one.
    public mutating func reset() {
        droppedAt = nil
        sentencesLocal = 0
    }
}
