import Testing
@testable import MoeVoice

/// What Moe says when it could not speak with the voice it was asked for.
///
/// The bug being guarded (2026-09-07): the owner picked the Cloud engine
/// and Clive, pressed "Use and preview", and heard Kokoro's Heart with
/// nothing on screen to say so. Every check here is one of the four facts
/// that were missing from that moment. Delete any one of them from
/// `VoiceFallback.sentence` and the matching test goes red.
struct VoiceFallbackTests {

    /// The exact case that was reported.
    private let cloudToKokoro = VoiceFallback(
        asked: "Cloud", used: "Kokoro", voice: "Heart — American female",
        why: "Alfie's cloud could not be reached just now")

    @Test func theSentenceNamesTheEngineThatWasChosen() {
        #expect(cloudToKokoro.sentence.contains("Cloud"),
                "a person who is not told which choice failed cannot tell a broken engine from a broken button")
    }

    @Test func theSentenceNamesTheEngineThatIsSpeaking() {
        #expect(cloudToKokoro.sentence.contains("Kokoro"))
    }

    /// The owner reported this by the *voice*, not the engine — "I heard
    /// the Kokoro voice and the heart voice" — so the voice is named.
    @Test func theSentenceNamesTheVoiceThatIsSpeaking() {
        #expect(cloudToKokoro.sentence.contains("Heart — American female"))
    }

    @Test func theSentenceGivesTheReason() {
        #expect(cloudToKokoro.sentence.contains("Alfie's cloud could not be reached just now"))
    }

    /// It has to read as one plain sentence, not a label. Whatever else
    /// changes, "couldn't be used" is the phrase that says the choice did
    /// not take, and it must come before the substitute is named — the
    /// first thing a person needs is that something failed.
    @Test func theFailureComesBeforeTheSubstitute() throws {
        let text = cloudToKokoro.sentence
        let failed = try #require(text.range(of: "couldn't be used"))
        let instead = try #require(text.range(of: "Kokoro"))
        #expect(failed.lowerBound < instead.lowerBound)
    }

    /// PocketTTS falls back the same way, through the same type — the cloud
    /// is not a special case, it is just the one that was reported.
    @Test func theSameSentenceCoversAnEngineThatIsNotDownloaded() {
        let fallback = VoiceFallback(
            asked: "PocketTTS", used: "Kokoro", voice: "Heart — American female",
            why: "it has not been downloaded on this Mac yet")
        #expect(fallback.sentence.contains("PocketTTS"))
        #expect(fallback.sentence.contains("has not been downloaded"))
    }

    /// The log's version carries the same four facts for a developer, and
    /// is stable enough to coalesce on: `VoiceEngine` skips writing a line
    /// identical to the last one, so two different failures must not
    /// produce the same string.
    @Test func theLogLineDistinguishesTwoDifferentFailures() {
        let spent = VoiceFallback(asked: "Cloud", used: "Kokoro", voice: "Heart — American female",
                                  why: "this month's cloud-voice allowance is used up")
        #expect(cloudToKokoro.logLine != spent.logLine)
        #expect(cloudToKokoro.logLine.contains("Cloud"))
        #expect(cloudToKokoro.logLine.contains("Kokoro"))
        #expect(spent.logLine.contains("allowance"))
    }
}
