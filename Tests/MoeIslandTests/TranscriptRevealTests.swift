import Testing
@testable import MoeIsland

/// Ticket #12, 2026-09-24: the owner pressed Transcript at 15:36:56 while
/// Moe worked, Moe answered aloud at 15:37:42, and the panel stayed shut —
/// "I don't see like the text that you're outputting". The button showed
/// their words and never Moe's.
struct TranscriptRevealTests {

    /// The owner's own setting (`panelOnReply: silent`) keeps a spoken answer
    /// off screen — unless the transcript is on, which is exactly the request
    /// to read it.
    @Test func aSpokenAnswerOpensThePanelWhileTheTranscriptIsOn() {
        #expect(!ReplyReveal.opens(meetingOn: false, speaksReply: true, policy: .silent))
        #expect(ReplyReveal.opens(meetingOn: false, speaksReply: true, policy: .silent, transcriptOn: true))
        // Pressing it is newer and more specific than any setting.
        #expect(ReplyReveal.opens(meetingOn: false, speaksReply: true, policy: .never, transcriptOn: true))
    }

    /// Off, nothing changes: the three policies answer as they always did.
    @Test func withTheTranscriptOffThePolicyStands() {
        #expect(!ReplyReveal.opens(meetingOn: false, speaksReply: true, policy: .silent, transcriptOn: false))
        #expect(!ReplyReveal.opens(meetingOn: false, speaksReply: false, policy: .never, transcriptOn: false))
        #expect(ReplyReveal.opens(meetingOn: false, speaksReply: true, policy: .always, transcriptOn: false))
    }

    /// The panel opens when Moe starts talking, not only when you do — the
    /// answer's words arrive with its voice rather than at the end of the
    /// turn.
    @Test func thePanelOpensWhenMoeStartsSpeaking() {
        #expect(ReplyReveal.transcriptOpens(listening: false, speaking: true, transcriptOn: true, collapsed: true))
        #expect(ReplyReveal.transcriptOpens(listening: true, speaking: false, transcriptOn: true, collapsed: true))
    }

    /// And only then: not while it works (the working row has the button),
    /// not with the transcript off, and never re-opening an open panel.
    @Test func itOpensNothingElse() {
        #expect(!ReplyReveal.transcriptOpens(listening: false, speaking: false, transcriptOn: true, collapsed: true))
        #expect(!ReplyReveal.transcriptOpens(listening: false, speaking: true, transcriptOn: false, collapsed: true))
        #expect(!ReplyReveal.transcriptOpens(listening: false, speaking: true, transcriptOn: true, collapsed: false))
    }
}
