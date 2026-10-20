import Foundation

/// How a turn reached Moe: through the microphone, or through a keyboard.
///
/// It existed before this type did, as an accident: `Conductor.submit` reads
/// `voice.takeTurnStart()`, which is nil for anything typed, and exactly one
/// caller — the instant acknowledgement — used that nil to mean "nobody is
/// waiting to *hear* this". Everything else that speaks read one global
/// switch, so a question typed into the island was answered out loud at a
/// person who had deliberately chosen not to talk.
///
/// A latency mark is a poor thing to hang a delivery decision on: it is
/// cleared by whoever reads it first, and it means "when did they stop
/// talking", not "how do they want to be answered". This says the second
/// thing and nothing else.
public enum TurnOrigin: String, Sendable, Codable {
    /// Held the key, or said the wake phrase, or spoke inside a conversation.
    case spoken
    /// Typed into the island's field, the chat window, or any other pane.
    case typed
}

/// Whether the answer to a turn is read out loud.
///
/// Three inputs, in the order they win:
///
///  1. **A meeting being recorded silences everything.** The room would hear
///     it and the call's microphone would carry it to everyone else. This has
///     always been true and is not a preference.
///  2. **The master switch.** "Speak replies out loud", off, means off.
///  3. **Where the turn came from.** Typed and spoken are separate answers to
///     separate questions, which is the whole point of this file.
public enum ReplyRoute {

    /// - Parameters:
    ///   - origin: how this turn reached Moe.
    ///   - master: `Config.speakReplies` — speech at all.
    ///   - typed: `Config.speakTypedReplies`.
    ///   - spoken: `Config.speakSpokenReplies`.
    ///   - meetingRecording: a meeting is being recorded right now.
    public static func speaks(origin: TurnOrigin,
                              master: Bool,
                              typed: Bool,
                              spoken: Bool,
                              meetingRecording: Bool) -> Bool {
        guard !meetingRecording, master else { return false }
        return origin == .typed ? typed : spoken
    }
}
