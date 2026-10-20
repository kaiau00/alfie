import Testing
@testable import MoeIsland

/// docs/PANEL-FINDINGS.md §1–§4. Every one of these is a complaint about the
/// island that could not be seen by reading the view.
struct IslandBehaviourTests {

    // MARK: - §2 Hover must not move the target

    /// Hover is how the meeting panel opens, because during a meeting there
    /// is nothing else to aim at: at rest the tab draws no pixels at all
    /// (`IslandView.recordingAtRest`), so requiring a click meant clicking an
    /// invisible strip under the cutout. This was briefly the other way
    /// round — see §2 in `IslandBehaviour` for why it came back.
    @Test func hoverOpensTheMeetingPanel() {
        #expect(IslandBehaviour.hoverEntered(current: .collapsed, meetingOn: true) == .peek)
    }

    /// Outside a meeting hover-to-peek is the whole way in, and stays.
    @Test func hoverStillPeeksOutsideAMeeting() {
        #expect(IslandBehaviour.hoverEntered(current: .collapsed, meetingOn: false) == .peek)
    }

    /// Hover never shrinks an open panel out from under someone reading it,
    /// and never wakes a hidden one.
    @Test func hoverOnlyEverActsFromCollapsed() {
        for state in [IslandPresentation.hidden, .peek, .expanded] {
            #expect(IslandBehaviour.hoverEntered(current: state, meetingOn: false) == nil)
            #expect(IslandBehaviour.hoverEntered(current: state, meetingOn: true) == nil)
        }
    }

    // MARK: - §3 A click inside the open panel must not close it

    /// The bug: the tap gesture sat on the island rather than on a control, so
    /// the transcript, the space beside the field — anything that was not
    /// itself a button — folded the panel away.
    @Test func aClickInsideTheOpenMeetingPanelDoesNothing() {
        #expect(IslandBehaviour.click(current: .expanded, meetingOn: true) == .ignore)
        #expect(IslandBehaviour.click(current: .peek, meetingOn: true) == .ignore)
    }

    /// And the click that matters still works: the collapsed tab opens the
    /// panel, in one click.
    @Test func theTabOpensTheMeetingPanel() {
        #expect(IslandBehaviour.click(current: .collapsed, meetingOn: true) == .open)
    }

    /// The owner's review, 2026-09-24: a click on the island opens it here
    /// and does nothing else. It used to open the main window from every
    /// state — so a click on empty space in an open panel threw a second
    /// window over the screen, or read a waiting reminder aloud. The window
    /// is one icon in the ⋯ tray now.
    @Test func outsideAMeetingAClickOpensTheIslandNotAWindow() {
        #expect(IslandBehaviour.click(current: .collapsed, meetingOn: false) == .open)
        #expect(IslandBehaviour.click(current: .peek, meetingOn: false) == .open)
        #expect(IslandBehaviour.click(current: .expanded, meetingOn: false) == .ignore)
    }

    /// The owner, 2026-09-25: "mute unmutes itself after some time". The
    /// folded red tab and the notch it hangs from are one target, and a
    /// click there unmuted (9c70b53a) — so reaching for the notch to look
    /// switched the mute off. A click on the island now only ever opens it.
    ///
    /// The switch is exhaustive on purpose: bring back a click that unmutes
    /// (an `IslandClick.unmute`) and this file stops compiling.
    @Test func clickingTheFoldedMutedTabExpandsAndNeverUnmutes() {
        for p in [IslandPresentation.hidden, .collapsed, .peek, .expanded] {
            for meeting in [false, true] {
                switch IslandBehaviour.click(current: p, meetingOn: meeting) {
                case .open, .ignore: break
                }
            }
        }
        #expect(IslandBehaviour.click(current: .collapsed, meetingOn: false) == .open)
    }

    /// Only the Unmute control unmutes, and only on a panel opened by hand.
    /// A hover peek drops down under a cursor on its way to the menu bar or
    /// a browser tab; a press there pins the panel and leaves the mute on.
    @Test func onlyTheUnmuteControlOnAnOpenedPanelUnmutes() {
        #expect(IslandBehaviour.unmutePress(current: .expanded) == .unmute)
        #expect(IslandBehaviour.unmutePress(current: .peek) == .open)
        #expect(IslandBehaviour.unmutePress(current: .collapsed) == .open)
        #expect(IslandBehaviour.unmutePress(current: .hidden) == .open)
    }

    @Test func theMutedTabShowsOnlyCollapsedMutedAndUnowned() {
        #expect(ConversationControls.showsMutedTab(presentation: .collapsed, muted: true,
                                                   meetingOn: false, dictating: false))
        #expect(!ConversationControls.showsMutedTab(presentation: .collapsed, muted: false,
                                                    meetingOn: false, dictating: false))
        #expect(!ConversationControls.showsMutedTab(presentation: .peek, muted: true,
                                                    meetingOn: false, dictating: false))
        #expect(!ConversationControls.showsMutedTab(presentation: .collapsed, muted: true,
                                                    meetingOn: true, dictating: false))
        #expect(!ConversationControls.showsMutedTab(presentation: .collapsed, muted: true,
                                                    meetingOn: false, dictating: true))
    }

    // MARK: - §1 The first click

    /// While collapsed, everything drawn has hit testing off, so the hosting
    /// view can take the mouse down itself — which is the one part of the
    /// first-click fix that does not depend on AppKit honouring a window flag.
    @Test func theHostViewTakesTheClickOnlyWhileCollapsed() {
        #expect(IslandBehaviour.hostViewTakesTheClick(current: .collapsed))
        for state in [IslandPresentation.hidden, .peek, .expanded] {
            #expect(!IslandBehaviour.hostViewTakesTheClick(current: state))
        }
    }

    /// Open, the click has to reach SwiftUI: the chevron, the stop button and
    /// the text field are real controls and the hosting view must not eat
    /// their events.
    @Test func theOpenPanelKeepsItsOwnControls() {
        #expect(!IslandBehaviour.hostViewTakesTheClick(current: .expanded))
    }

    // MARK: - §4 "Be visible" is not "be closed"

    /// The bug: a dozen ordinary events — a wake word, a nudge, a bookmark —
    /// all answered "be visible" with a collapse, which shut an open meeting
    /// panel mid-sentence.
    @Test func wantingToBeVisibleLeavesAnOpenPanelAlone() {
        #expect(IslandBehaviour.visibility(.wantsVisible, current: .expanded) == nil)
        #expect(IslandBehaviour.visibility(.wantsVisible, current: .peek) == nil)
        #expect(IslandBehaviour.visibility(.wantsVisible, current: .collapsed) == nil)
    }

    /// It still brings the island back when there is nothing on screen —
    /// which is the request's actual job.
    @Test func wantingToBeVisibleWakesAHiddenIsland() {
        #expect(IslandBehaviour.visibility(.wantsVisible, current: .hidden) == .collapsed)
    }

    /// Dismissing is the other request, and it does fold.
    @Test func dismissingFolds() {
        #expect(IslandBehaviour.visibility(.dismissed, current: .expanded) == .collapsed)
        #expect(IslandBehaviour.visibility(.dismissed, current: .peek) == .collapsed)
    }

    /// Never all the way off: the faint idle glow is how you know Moe is
    /// running. Dismissing collapses it, it does not switch it off.
    @Test func dismissingNeverHides() {
        #expect(IslandBehaviour.visibility(.dismissed, current: .hidden) == .collapsed)
        #expect(IslandBehaviour.visibility(.dismissed, current: .collapsed) == nil)
    }
}

/// The island's own signal: what outranks what, and where the stop lives.
///
/// This is the replacement for the hands-off guard, so it is the thing that
/// has to be right. The guard tried to infer "the person wants me to stop"
/// from the CGEvent stream and could not — cua-driver's foreground path posts
/// "a genuine HID key transition" precisely so Chromium cannot tell it from
/// hardware, which means source pid 0, the same as the keyboard. Three
/// thresholds were tried in one evening and every one fired on Moe rather
/// than the owner, refusing four of his sessions and telling him each time
/// that he had touched a mouse he had not touched.
@Suite struct IslandOverrideTests {

    @Test func drivingOutranksEverything() {
        // The state a person most needs to recognise without being told, and
        // the only one they may want to end mid-flight.
        #expect(IslandOverride.of(driving: true, nudgeWaiting: true, idle: true) == .driving)
        #expect(IslandOverride.of(driving: true, nudgeWaiting: false, idle: false) == .driving)
        #expect(IslandOverride.of(driving: true, nudgeWaiting: true, idle: false) == .driving)
    }

    @Test func aNudgeOnlyShowsWhenMoeIsOtherwiseIdle() {
        // A nudge is Moe waiting to be asked; it must not colour the island
        // over the top of Moe actually doing something.
        #expect(IslandOverride.of(driving: false, nudgeWaiting: true, idle: true) == .nudge)
        #expect(IslandOverride.of(driving: false, nudgeWaiting: true, idle: false) == .none)
    }

    @Test func nothingSpecialFallsThroughToTheVoiceState() {
        #expect(IslandOverride.of(driving: false, nudgeWaiting: false, idle: true) == .none)
        #expect(IslandOverride.of(driving: false, nudgeWaiting: false, idle: false) == .none)
    }

    @Test func theStopIsOfferedWhileDrivingAndOnlyThen() {
        // The prominent control becomes a hard stop, and does so in exactly
        // one state. An island that offers a stop while merely listening
        // teaches people the button means something else.
        #expect(IslandOverride.driving.offersStop)
        #expect(!IslandOverride.nudge.offersStop)
        #expect(!IslandOverride.none.offersStop)
    }

    /// The stop names what it stops. "Stop" alone shipped and the report was
    /// that the way to end a run could not be found — the person is looking
    /// for "browser use" or "computer use", so those are the words.
    @Test func theStopNamesWhatItStops() {
        #expect(IslandOverride.stopLabel(screen: true) == "End computer use")
        #expect(IslandOverride.stopLabel(screen: false) == "End browser use")
        for screen in [true, false] {
            #expect(IslandOverride.stopLabel(screen: screen).count <= 16, "fits a chip on the notch")
        }
    }
}

/// Hovering while Moe works — the state the stop and Work silently live in.
///
/// Reported 2026-09-06 for driving: "while it's doing the work, you can't
/// hover over the island. The dropdown doesn't come." Fixed for driving only,
/// and reported again 2026-09-19 for everything else a job does: "when he's
/// thinking and you hover over it, there's not [a dropdown]."
///
/// The cause both times was a refusal keyed on `acting`, which is true from
/// the first tool step to the end of the turn — so the peek panel was
/// unreachable for exactly as long as there was a stop to press or a Work
/// silently to switch. The rule no longer reads what Moe is doing at all:
/// there is no argument for it to take, so no future state can be added to
/// the refusal by mistake.
@Suite struct IslandHoverWhileWorkingTests {

    @Test func hoverOpensThePeekWhateverMoeIsDoing() {
        // The only inputs left are the presentation and the meeting flag;
        // acting, driving and browsing cannot be passed, let alone refused.
        #expect(IslandBehaviour.hoverEntered(current: .collapsed, meetingOn: false) == .peek)
        #expect(IslandBehaviour.hoverEntered(current: .collapsed, meetingOn: true) == .peek)
    }

    @Test func thePanelOnlyOpensFromCollapsed() {
        // Must not re-open something already open, or re-promote a meeting
        // tab mid-press.
        for state in [IslandPresentation.peek, .expanded, .hidden] {
            #expect(IslandBehaviour.hoverEntered(current: state, meetingOn: false) == nil,
                    "\(state)")
        }
    }
}

/// The driving colour has to be unlike every other island state, and "unlike"
/// is a measurement rather than an opinion.
///
/// The first attempt was a teal whose own comment claimed it was
/// "unmistakable against every other state". It sat 14° from `speaking` and
/// 27° from `listening`, and the owner's report was "my thing is green now".
@Suite struct IslandDrivingColourTests {

    /// Hue in degrees, the only axis that decides whether two lights read as
    /// the same colour across a room.
    private func hue(_ rgb: UInt32) -> Double {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        if d == 0 { return 0 }
        let h: Double
        if mx == r { h = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6)) }
        else if mx == g { h = 60 * ((b - r) / d + 2) }
        else { h = 60 * ((r - g) / d + 4) }
        return h < 0 ? h + 360 : h
    }

    private func separation(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 360 - d)
    }

    @Test func drivingIsFarFromEveryOtherIslandState() {
        // Measured off Theme.swift, 2026-09-06; thinking, speaking and idle
        // became Moe's white light on 2026-09-24 and have no hue to crowd.
        let others: [(String, UInt32)] = [
            ("recording", 0xE26055), ("amber", 0xE8A64A), ("you", 0x8FD0A8),
            ("listening", 0x59D98C), ("them", 0x94B3E8),
            ("dictation", 0xB79AF5),
        ]
        let driving = hue(0xFF3FA4)
        for (name, rgb) in others {
            let gap = separation(driving, hue(rgb))
            #expect(gap >= 30, "driving is only \(Int(gap))° from \(name)")
        }
    }

    @Test func theTealItReplacedWouldFailThisTest() {
        // The guard has to be able to catch the mistake it was written for,
        // or it is decoration.
        #expect(separation(hue(0x3FC8B4), hue(0x73D9B3)) < 30,
                "the old driving colour was 14° from speaking")
    }
}
