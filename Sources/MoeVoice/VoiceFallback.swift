import Foundation

/// Moe could not speak with the voice it was asked for, and here is what to
/// say about it.
///
/// **The bug this exists for.** On 2026-09-07 the owner chose the Cloud
/// engine and Clive, pressed "Use and preview", and heard Kokoro's Heart.
/// Nothing on screen said anything had failed; the picker still read
/// "Cloud" and "Clive". The only trace was one line in `~/.moe/logs/moe.log`
/// — and even that was written at most once per process, so the second and
/// third presses were completely silent while the log's very next line said
/// `voice: Cloud warmed in 818 ms` about a Kokoro render.
///
/// A substitution nobody is told about is indistinguishable from a setting
/// that did not take, which is exactly how it was reported: "something's
/// wrong with the cloud voice". Falling back is right — a Mac with no
/// network must still speak — but falling back *quietly* is the bug, and it
/// will happen again on a plane or behind a proxy long after the edge works.
///
/// Pure, and in this target on purpose: `VoiceEngine` and `TtsEngineKind`
/// live in the `Moe` executable target, which no test can import (see
/// `CloudEngineTests`). The sentence a person actually reads is therefore
/// written here, where `MoeVoiceTests` can hold it to its words.
public struct VoiceFallback: Equatable, Sendable {

    /// The engine the person chose, by its Settings name ("Cloud").
    public let asked: String
    /// The engine that is going to speak instead ("Kokoro").
    public let used: String
    /// The voice that is going to speak, as Settings labels it
    /// ("Heart — American female"). The owner named the voice, not the
    /// engine, when reporting this — "I heard … the heart voice" — so the
    /// sentence names it too.
    public let voice: String
    /// Why, in the person's words and never a raw error: "Moe's cloud
    /// could not be reached". Not capitalised and with no full stop; it is
    /// used mid-sentence.
    public let why: String

    public init(asked: String, used: String, voice: String, why: String) {
        self.asked = asked
        self.used = used
        self.voice = voice
        self.why = why
    }

    /// One line for the person: what they chose, that it did not happen,
    /// what is speaking instead, and why — in that order, because the first
    /// thing they need to know is that the thing they pressed did not take.
    ///
    /// It always contains all four, and that is what
    /// `VoiceFallbackTests` holds it to: a message that names the failure
    /// but not the substitute leaves them hearing a mystery voice, and one
    /// that names the substitute but not the reason cannot be acted on.
    public var sentence: String {
        "\(asked) couldn't be used — \(why). Alfie is speaking with \(used), "
            + "in \(voice), until that changes."
    }

    /// The same fact for `~/.moe/logs/moe.log`, where a developer wants the
    /// engine names and not the reassurance.
    public var logLine: String {
        "voice: asked for \(asked), speaking with \(used) (\(voice)) — \(why)"
    }
}
