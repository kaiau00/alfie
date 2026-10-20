import Foundation
import Testing
@testable import MoeIsland

/// docs/FIXABLE-FAILURES.md bugs 10 and 11: the rules. What the real island
/// view does with them is `IslandMuteTests` (MoeAppTests).
///
/// 2026-09-23, 21:39: the owner pressed mute on the working row, the brain's
/// turn ended, the row went with it, and while Moe spoke and then listened
/// for a follow-up there was no mute on the island at all.
struct ConversationControlsTests {

    // MARK: - Mute, for the whole conversation

    /// The four phases of a spoken conversation, each as the open panel
    /// shows it. Every one must carry mute.
    @Test func muteIsReachableInEveryPhaseOfAConversation() {
        // thinking / acting: the working row
        #expect(ConversationControls.muteRow(working: true, voiced: false, transcriptShown: false,
                                             inConversation: true, muted: false) == .working)
        // speaking: the turn is over, the answer's voice is out
        #expect(ConversationControls.muteRow(working: false, voiced: true, transcriptShown: false,
                                             inConversation: true, muted: false) == .reply)
        // the follow-up window / listening: nothing is voiced, nothing running
        #expect(ConversationControls.muteRow(working: false, voiced: false, transcriptShown: false,
                                             inConversation: true, muted: false) == .conversation)
        // listening with the transcript asked for
        #expect(ConversationControls.muteRow(working: false, voiced: false, transcriptShown: true,
                                             inConversation: true, muted: false) == .transcript)
    }

    /// Muted is also the way to unmute, so it never disappears while on.
    @Test func mutedStaysUnmutable() {
        #expect(ConversationControls.muteRow(working: false, voiced: false, transcriptShown: false,
                                             inConversation: false, muted: true) != nil)
    }

    /// A typed turn is not listening: nothing to mute.
    @Test func noMuteOutsideAConversation() {
        #expect(ConversationControls.muteRow(working: true, voiced: true, transcriptShown: true,
                                             inConversation: false, muted: false) == nil)
    }

    // MARK: - ▶ ↺ ⋯ on every answer

    @Test func playIsTheChatsRule() {
        // a finished answer, nothing working: ▶
        #expect(ConversationControls.canPlay(isMoe: true, streaming: false, hasText: true,
                                             voiced: false, thinking: false))
        // mid-turn another reply owns the voice…
        #expect(!ConversationControls.canPlay(isMoe: true, streaming: false, hasText: true,
                                              voiced: false, thinking: true))
        // …except the one being said, which ⏸ must still reach
        #expect(ConversationControls.canPlay(isMoe: true, streaming: false, hasText: true,
                                             voiced: true, thinking: true))
        #expect(!ConversationControls.canPlay(isMoe: true, streaming: true, hasText: true,
                                              voiced: false, thinking: false))
        #expect(!ConversationControls.canPlay(isMoe: false, streaming: false, hasText: true,
                                              voiced: false, thinking: false))
        #expect(!ConversationControls.canPlay(isMoe: true, streaming: false, hasText: false,
                                              voiced: false, thinking: false))
    }
}
