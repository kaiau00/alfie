import Foundation
import SwiftUI
import Testing
import MoeIsland
@testable import Moe

/// docs/FIXABLE-FAILURES.md bug 10, read off the real island view.
///
/// 2026-09-23, 21:39: mute was pressed on the working row, the brain's turn
/// ended, the row went — and while Moe spoke the answer and then listened
/// for more there was no mute anywhere on the island. Each phase is posed
/// on a real Conductor (the snapshot seam) and the real `IslandView` is
/// asked for its tray (`IslandTray`, the dropdown of 2026-09-24): the mic is
/// in it for the whole conversation, exactly once.
@MainActor
struct IslandMuteTests {

    private func island(_ presentation: NotchIsland.Presentation = .expanded,
                        _ pose: (inout Conductor.SnapshotState) -> Void) throws -> IslandView {
        // A real Conductor, so the same scratch-home rule as the turn tests.
        try StallGuardConductorTests.requireScratchHome()
        var s = Conductor.SnapshotState()
        s.inConversation = true
        pose(&s)
        let conductor = Conductor(config: Config())
        conductor.pose(s)
        return IslandView(conductor: conductor, presentation: presentation,
                          notchSize: .zero, contentSize: CGSize(width: 420, height: 300),
                          draft: IslandDraft(), takesFocus: false,
                          onTap: {}, onHover: { _ in })
    }

    private static let answer = Turn(role: .moe, text: "The cheapest on the 30th is VietJet at $142.")

    private func mics(_ view: IslandView) -> [IslandTray.Control] {
        view.trayControls.filter { if case .mic = $0 { return true } else { return false } }
    }

    @Test func whileMoeWorksMuteIsInTheTray() throws {
        let view = try island { $0.mode = .thinking; $0.working = true; $0.acting = true }
        #expect(mics(view) == [.mic(muted: false)])
        #expect(view.trayControls.contains(.stop(driving: false)))
    }

    /// The turn is over and the answer is being said.
    @Test func whileMoeSpeaksMuteIsBesidePause() throws {
        let view = try island { s in
            s.mode = .speaking
            s.turns = [Self.answer]
            s.voicedTurn = 0
        }
        #expect(mics(view) == [.mic(muted: false)])
        #expect(view.trayControls.contains(.pause))
    }

    /// The follow-up window: nothing running, nothing voiced.
    @Test func whileMoeListensForMoreMuteIsStillThere() throws {
        let view = try island { s in
            s.mode = .listening
            s.turns = [Self.answer]
        }
        #expect(mics(view) == [.mic(muted: false)])
    }

    /// Muted, it stays reachable — it is also the way back — and it is drawn
    /// outside the ⋯ too, so it never hides behind a click.
    @Test func mutedStaysOnTheIsland() throws {
        let view = try island { s in
            s.mode = .listening
            s.micMuted = true
            s.turns = [Self.answer]
        }
        #expect(mics(view) == [.mic(muted: true)])
        #expect(IslandTray.mutedOutside(true))
    }

    // MARK: - Sticky mute, unmistakable (the owner, 2026-09-24)

    /// After the answer the island folds. Muted, it must still say so:
    /// "Muted" in the left ear beside the notch (white since 2026-10-15; it
    /// was a red tab under it), from the same value (`Conductor.micMuted`)
    /// the tray and the chat read.
    @Test func mutedAndFoldedSaysMuted() throws {
        let view = try island(.collapsed) { s in
            s.mode = .listening
            s.micMuted = true
            s.turns = [Self.answer]
        }
        #expect(view.showsMutedTab)
        // A label, not an instruction to tap: a tap opens the island.
        #expect(ConversationControls.mutedPill == "Muted")
    }

    // MARK: - Mute that "unmuted itself" (the owner, 2026-09-25)

    private func island(_ presentation: NotchIsland.Presentation, onTap: @escaping () -> Void,
                        _ pose: (inout Conductor.SnapshotState) -> Void) throws -> IslandView {
        try StallGuardConductorTests.requireScratchHome()
        var s = Conductor.SnapshotState()
        s.inConversation = true
        pose(&s)
        let conductor = Conductor(config: Config())
        conductor.pose(s)
        return IslandView(conductor: conductor, presentation: presentation,
                          notchSize: .zero, contentSize: CGSize(width: 420, height: 300),
                          draft: IslandDraft(), takesFocus: false,
                          onTap: onTap, onHover: { _ in })
    }

    /// A press on Unmute over a panel that only dropped down on hover pins
    /// the panel (the island's own click) instead of unmuting. Opened by
    /// hand, the same press does not go to the click: it unmutes.
    @Test func unmuteOnAHoverPeekPinsThePanelInstead() throws {
        var taps = 0
        let peek = try island(.peek, onTap: { taps += 1 }) { s in
            s.mode = .listening; s.micMuted = true; s.turns = [Self.answer]
        }
        peek.pressUnmute()
        #expect(taps == 1, "a press on a hover peek must pin it, not unmute")
        #expect(peek.conductor.micMuted)

        taps = 0
        let open = try island(.expanded, onTap: { taps += 1 }) { s in
            s.mode = .listening; s.micMuted = true; s.turns = [Self.answer]
        }
        open.pressUnmute()
        #expect(taps == 0, "on a panel opened by hand the press is the unmute")
    }

    /// "When muted it still tracks my voice": posed with the microphone
    /// loud, the real view's left ear says Muted and draws no level bars,
    /// and does draw them when not muted (the control — an ear that never
    /// showed bars would pass the first half).
    @Test func mutedTheEarIgnoresALoudMicrophone() throws {
        let muted = try island(.collapsed) { s in
            s.mode = .listening; s.micMuted = true; s.level = 0.95
        }
        #expect(muted.ears.left == .muted)
        let live = try island(.collapsed) { s in
            s.mode = .listening; s.level = 0.95
        }
        #expect(live.ears.left == .levels)
    }

    @Test func notMutedNoTab() throws {
        let view = try island(.collapsed) { s in
            s.mode = .listening
            s.turns = [Self.answer]
        }
        #expect(!view.showsMutedTab)
    }

    /// Open, the tab is not drawn: the red mic in the panel is.
    @Test func openPanelHasTheMicNotTheTab() throws {
        let view = try island(.expanded) { s in
            s.mode = .listening
            s.micMuted = true
            s.turns = [Self.answer]
        }
        #expect(!view.showsMutedTab)
        #expect(mics(view) == [.mic(muted: true)])
    }

    /// A typed exchange is not listening: nothing to mute.
    @Test func noMuteOutsideAConversation() throws {
        let view = try island { s in
            s.inConversation = false
            s.mode = .idle
            s.turns = [Self.answer]
        }
        #expect(mics(view).isEmpty)
    }

    /// The owner, 2026-09-24: "every time I say Hey Moe it opens up, every
    /// time there's an answer it opens up". The live transcript had been
    /// pressed at 17:33 and stayed on, invisibly, for the rest of the day.
    /// It now ends with the conversation.
    @Test func theLiveTranscriptEndsWithTheConversation() throws {
        try StallGuardConductorTests.requireScratchHome()
        let conductor = Conductor(config: Config())
        var s = Conductor.SnapshotState()
        s.inConversation = true
        conductor.pose(s)
        conductor.toggleTranscript()
        #expect(conductor.showsTranscript)
        s.inConversation = false
        conductor.pose(s)
        #expect(!conductor.showsTranscript, "the transcript outlived the conversation")
    }


    /// The owner, 2026-09-24: "when it stops thinking, it shows 'thinking',
    /// and then it doesn't show any of the transcripts anymore." While Moe
    /// works, the whole session stays in the chat and the step is added
    /// under it as the newest row.
    @Test func whileMoeWorksTheConversationStays() throws {
        try StallGuardConductorTests.requireScratchHome()
        var s = Conductor.SnapshotState()
        s.inConversation = true
        s.mode = .thinking
        s.working = true
        s.turns = [Turn(role: .you, text: "first question"),
                   Turn(role: .moe, text: "first answer"),
                   Turn(role: .you, text: "second question")]
        let conductor = Conductor(config: Config())
        conductor.pose(s)
        let rows = IslandView.chatRows(conductor)
        #expect(rows.count == 4)
        if case .working = rows.last {} else { Issue.record("the step is not the newest row") }
        if case .moe(_, let text) = rows[1] { #expect(text == "first answer") }
        else { Issue.record("the earlier answer left the chat") }
    }


    /// The owner, 2026-09-25: the field is always there now, so a message
    /// typed while Moe is still on the last one has to go somewhere. It is
    /// held, shown as waiting, and sent the moment the turn finishes — it
    /// used to be dropped with "Still working on the last one — one sec."
    @Test func aMessageTypedMidTurnIsHeldAndSentAfter() throws {
        try StallGuardConductorTests.requireScratchHome()
        let conductor = Conductor(config: Config())
        var s = Conductor.SnapshotState()
        s.mode = .thinking
        s.awaitingReply = true
        s.turns = [Turn(role: .you, text: "first")]
        conductor.pose(s)
        conductor.submit("and also this", origin: .typed, starter: .person)
        #expect(conductor.queuedTyped == "and also this")
        #expect(!conductor.turns.contains { $0.text.hasPrefix("Still working") },
                "the message was dropped instead of held")
        if case .queued(let text) = IslandView.chatRows(conductor).last(where: {
            if case .queued = $0 { return true } else { return false } }) {
            #expect(text == "and also this")
        } else { Issue.record("the held message is not in the chat") }
        conductor.stopEverything()
        #expect(conductor.queuedTyped == nil, "stopping Alfie left a held message to send itself")
    }

}
