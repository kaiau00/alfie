import Foundation

/// How much of the island is drawn. Lives here rather than nested in
/// `NotchIsland` so the rules below — which are the whole of what "click",
/// "hover" and "be visible" mean — can be tested without AppKit.
/// `NotchIsland.Presentation` is a typealias for this.
public enum IslandPresentation: Equatable, Sendable {
    case hidden, collapsed, peek, expanded

    /// Anything a person can see and aim at.
    public var isOnScreen: Bool { self != .hidden }
    /// The panel is unfurled: there is something to read and something to
    /// type into.
    public var isOpen: Bool { self == .peek || self == .expanded }
}

/// What a click on the island's own body means.
public enum IslandClick: Equatable, Sendable {
    /// Open the panel here, by hand.
    case open
    /// Nothing. docs/PANEL-FINDINGS.md §3.
    case ignore
}

/// What a press on the island's Unmute control does (2026-09-25).
public enum UnmutePress: Equatable, Sendable {
    /// Unmute: the panel was opened by hand and the control was pressed.
    case unmute
    /// Pin the panel open and leave the mute alone: the panel is a hover
    /// peek that dropped down under a cursor on its way somewhere else.
    case open
}

/// Why something wants the island on screen.
public enum IslandVisibility: Equatable, Sendable {
    /// "Be visible" — a wake word, a nudge, a bookmark, a dozen other
    /// ordinary events.
    case wantsVisible
    /// "Be closed" — the conversation ended, the nudge was dismissed, the
    /// user stopped everything.
    case dismissed
}

/// The island's gesture rules, as pure functions of the state they read.
///
/// Every one of these encodes a numbered finding in docs/PANEL-FINDINGS.md.
/// They are here, in a library target, because an executable target cannot
/// be imported by a test — and because the bugs they fix are all invisible
/// in the view code that used to hold them.
public enum IslandBehaviour {

    // MARK: - §2 Hover must not move the target

    /// Where the cursor arriving should take the island, or nil to leave it
    /// exactly where it is.
    ///
    /// **§2.** Collapsed during a meeting, hover promotes the island to
    /// `.peek` — swapping a 152 pt tab for a 372 pt panel. That was removed
    /// once, on the reasoning that aiming at the tab and pressing lands the
    /// press on a view that is no longer there. It cost more than it saved:
    /// while a meeting records at rest the tab draws *nothing* (see
    /// `IslandView.recordingAtRest`), so with hover gone the only way to the
    /// transcript was a click on an invisible strip under the cutout. A
    /// gesture nobody can see is not a gesture. Hover is the way in again.
    ///
    /// The press that §2 worried about is already handled: during a meeting
    /// `click` returns `.ignore` for an open panel, so a press that lands
    /// inside the panel it just opened does nothing at all unless it hits a
    /// real control. The panel closes by its own chevron.
    ///
    /// Hover opens the peek from collapsed in every state Moe can be in.
    ///
    /// This used to refuse while `acting` — Moe thinking, searching, reading
    /// mail, driving the Mac — on the grounds that its synthesised clicks
    /// moved the cursor, so a pass near the notch would open the panel and
    /// swallow the next click. That premise went with the foreground driver:
    /// cua-driver posts input through SkyLight and the real cursor never
    /// moves. What the refusal actually did was hide the panel for exactly
    /// as long as there was anything on it: the stop that ends a run and the
    /// **Work silently** switch both live on the peek, and the peek is reached
    /// by hovering. Reported 2026-09-06 for driving ("while it's doing the
    /// work, you can't hover over the island. The dropdown doesn't come") and
    /// fixed for driving only; reported again 2026-09-19 for the rest of a
    /// job ("when he's thinking and you hover over it, there's not"). A panel
    /// the docs say to hover for has to open on hover, whatever Moe is doing.
    public static func hoverEntered(current: IslandPresentation,
                                    meetingOn: Bool) -> IslandPresentation? {
        current == .collapsed ? .peek : nil
    }

    // MARK: - §1/§3 The click

    /// What a click on the island does.
    ///
    /// **§3.** The tap gesture sat on the island, not on a control, so the
    /// transcript, the space beside the text field — anything that was not
    /// itself a button — folded the panel away, and getting back cost another
    /// click. An open meeting panel closes by its own chevron and nothing
    /// else.
    ///
    /// Outside a meeting a click used to open the main window from every
    /// state, so a click on empty panel space threw a second window over the
    /// screen or read a waiting reminder aloud (the owner's review,
    /// 2026-09-24). A click on the island now opens the island, and nothing
    /// else; the window is an icon in the ⋯ tray (`IslandTray.openChat`).
    ///
    /// **A click never unmutes** (the owner, 2026-09-25: "mute unmutes
    /// itself after some time"). Collapsed and muted, the red "Muted" tab is
    /// drawn under the notch (`ConversationControls.showsMutedTab`), and a
    /// click on it — or on the notch beside it, which is the same target —
    /// opens the island like any other click. It used to unmute (9c70b53a),
    /// so reaching for the notch to *look* switched the mute off. Unmuting is
    /// the Unmute control on the open panel and nothing else
    /// (`unmutePress`).
    public static func click(current: IslandPresentation, meetingOn: Bool) -> IslandClick {
        // Open already: a click on the panel's own space does nothing. A
        // hover peek outside a meeting is pinned open by the click (it then
        // stays until Esc, ⌃ or a click elsewhere); a meeting's hover panel
        // is already the whole panel.
        switch current {
        case .collapsed, .hidden: return .open
        case .peek: return meetingOn ? .ignore : .open
        case .expanded: return .ignore
        }
    }

    /// What a press on the panel's Unmute control does.
    ///
    /// Only a panel opened by hand (`.expanded`) unmutes. A hover peek drops
    /// the whole panel down under a cursor that was on its way to a browser
    /// tab or the menu bar, and a click meant for that lands on whatever is
    /// under it; there, the press pins the panel open (as a click on a peek
    /// does, `click`) and the mute stays on. Collapsed or hidden there is no
    /// control to press — the answer is `.open` so nothing can unmute by
    /// being reached from a state it should not be.
    public static func unmutePress(current: IslandPresentation) -> UnmutePress {
        current == .expanded ? .unmute : .open
    }

    /// Whether the hosting view should take the mouse down itself rather than
    /// hand it to SwiftUI.
    ///
    /// **§1, part three — the part that cannot fail.** While the island is
    /// collapsed every drawn thing is `allowsHitTesting(false)`: the halo, the
    /// working arc, the consent ring and the meeting tab. So nothing is lost
    /// by having `hitTest` return the hosting view and letting it handle
    /// `mouseDown` directly, and what is gained is a click that survives a
    /// window that is not key — no gesture recogniser, nothing that can be
    /// rebuilt mid-click.
    public static func hostViewTakesTheClick(current: IslandPresentation) -> Bool {
        current == .collapsed
    }

    // MARK: - §4 "Be visible" is not "be closed"

    /// Where a visibility request should take the island, or nil for "leave
    /// it alone".
    ///
    /// **§4.** `onWantsIsland(true)` fires on a dozen ordinary events — a wake
    /// word, a nudge arriving, a meeting bookmark, the push-to-talk key. Each
    /// one used to be answered with `show(expanded: false)`, which collapses,
    /// so each one slammed an open meeting panel shut mid-sentence. Wanting to
    /// be *seen* is satisfied by already being on screen.
    public static func visibility(_ request: IslandVisibility,
                                  current: IslandPresentation) -> IslandPresentation? {
        switch request {
        case .wantsVisible:  return current.isOnScreen ? nil : .collapsed
        case .dismissed:     return current == .collapsed ? nil : .collapsed
        }
    }
}

/// The self-opening panel and the clock that folds it again.
///
/// docs/PANEL-FINDINGS.md §7. The island's standing rule that it never
/// expands on its own was written for a *spoken* assistant, where the answer
/// reaches you whether or not anything is on screen. That rule is wrong for a
/// reply that is text only.
public enum ReplyReveal {

    /// How long a reply gets on screen before the panel folds itself away.
    /// Long enough to read a few lines; short enough that a panel sitting
    /// over somebody's video call is not still there a minute later.
    ///
    /// The default rather than the law: `readingTime(seconds:)` is what the
    /// panel actually asks.
    public static let readingTime: TimeInterval = 12

    /// The clock a person has chosen, made safe.
    ///
    /// Zero — and anything else that is not a usable number of seconds —
    /// means "leave it up until I dismiss it", which the caller expresses by
    /// never starting a clock at all. The ceiling is an hour: a panel that
    /// self-opened over somebody's screen and stayed for a day is a bug
    /// however it was configured.
    public static func readingTime(seconds: Double) -> TimeInterval? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        return min(seconds, 3600)
    }

    /// Whether an answer should pull the panel open at all.
    ///
    /// The rule used to be derived: open only when the answer is text and
    /// nothing else. While a meeting is recorded replies are shown and never
    /// spoken, so the panel is the only place the answer exists; the same is
    /// true anywhere spoken replies are switched off. When Moe speaks, the
    /// answer already reached you and a panel over your screen is an
    /// interruption, not a delivery.
    ///
    /// That is still the default — `.silent` — but it was a preference
    /// wearing the clothes of a law, and two reasonable people want the other
    /// two answers: read along while Moe talks, or never have a panel appear
    /// over anything.
    ///
    /// A recorded meeting is the one case no preference reaches. The reply is
    /// not being spoken and the panel is the only copy of it, so `.never`
    /// there would mean an answer that exists nowhere.
    ///
    /// The Transcript button is the other. It is pressed to *read* the
    /// conversation, and it used to show only the person's own words: the
    /// moment Moe answered aloud the panel stayed shut under `.silent`, so the
    /// one thing the button was pressed for — Moe's words — never appeared
    /// (ticket #12, "I don't see the text that you're outputting"). While it
    /// is on, an answer opens the panel whatever the policy says: pressing it
    /// is a newer and more specific request than any setting.
    public static func opens(meetingOn: Bool,
                             speaksReply: Bool,
                             policy: PanelReveal = .silent,
                             transcriptOn: Bool = false) -> Bool {
        if meetingOn || transcriptOn { return true }
        switch policy {
        case .always: return true
        case .never:  return false
        case .silent: return !speaksReply
        }
    }

    /// With the transcript on, whether a shut panel should open now.
    ///
    /// It used to open only when the person started talking — so their
    /// words appeared, and Moe's answer, spoken seconds later into a panel
    /// that had folded while it worked, did not. `onReply` fires when the
    /// brain is done, after the speaking has begun; this is the moment the
    /// words start, so the text arrives with the voice.
    public static func transcriptOpens(listening: Bool, speaking: Bool,
                                       transcriptOn: Bool, collapsed: Bool) -> Bool {
        transcriptOn && collapsed && (listening || speaking)
    }

    /// What the reading clock should do when it comes due.
    public enum Tick: Equatable, Sendable {
        /// Fold the panel away.
        case fold
        /// Start the clock again: the person is still using this.
        case wait
    }

    /// Three ways of saying "this is in use": the cursor resting on the
    /// panel, a half-typed question in the field, or the field simply holding
    /// the keyboard — somebody clicked into it and is thinking about what to
    /// ask. Taking the panel away in any of those is taking it away mid-use.
    ///
    /// Restart rather than cancel, so a panel left under an abandoned cursor
    /// still folds once the cursor moves.
    public static func due(cursorOverIsland: Bool,
                           draftInProgress: Bool,
                           holdsTheKeyboard: Bool) -> Tick {
        (cursorOverIsland || draftInProgress || holdsTheKeyboard) ? .wait : .fold
    }

    /// A click in another app gives up at once. No grace period: the panel is
    /// sitting over somebody's video call, and a click somewhere else is the
    /// clearest possible statement that they are done with it.
    ///
    /// A click on the island itself is not one of these — it is the person
    /// using the thing — so the pointer is checked rather than trusting that
    /// a global monitor never sees our own window's events.
    public static func outsideClickFolds(cursorOverIsland: Bool) -> Bool {
        !cursorOverIsland
    }
}

/// When the island opens itself to show an answer.
///
/// Before this, the answer was derived from whether Moe was going to speak
/// (`ReplyReveal.opens`), which is a good default and a bad law. Somebody who
/// wants to read along while Moe talks had no way to say so, and somebody who
/// never wants a panel over a shared screen had no way to say that either.
public enum PanelReveal: String, Sendable, Codable, CaseIterable {
    /// Every answer opens the panel.
    case always
    /// Only an answer Moe will not speak. The default, and how the island
    /// behaved before there was a choice.
    case silent
    /// Never on its own. The answer is in the chat window, and the panel
    /// opens when you open it.
    case never

    /// Tolerant of a hand-edited config.json: unknown text is the default,
    /// because the menu invites people to edit that file.
    public init(configValue: String) {
        self = PanelReveal(rawValue: configValue) ?? .silent
    }

    /// For the settings pane.
    public var label: String {
        switch self {
        case .always: return "Always"
        case .silent: return "Only when Moe stays quiet"
        case .never:  return "Never"
        }
    }
}

/// What the island is saying about itself, when that outranks the voice state.
///
/// Extracted from `IslandView` so the priority and the stop rule can be tested
/// without AppKit. Both were decided in a view's private computed property,
/// where the only way to check them was to look at the screen — and the state
/// this exists for is the one nobody was looking at.
public enum IslandOverride: Equatable, Sendable {
    /// Moe has the screen: clicking and typing in an app right now.
    case driving
    /// Something is waiting to be asked about, and Moe is otherwise idle.
    case nudge
    /// Nothing outranks the voice state; show listening / thinking / speaking.
    case none

    /// Driving beats a nudge, and both beat the voice state.
    ///
    /// The order is not arbitrary. Driving is the state a person most needs to
    /// recognise unprompted and the only one they may want to end mid-flight;
    /// a nudge can wait, by definition — it is Moe waiting to be asked.
    public static func of(driving: Bool, nudgeWaiting: Bool, idle: Bool) -> IslandOverride {
        if driving { return .driving }
        if nudgeWaiting && idle { return .nudge }
        return .none
    }

    /// Whether the island's prominent control is a hard stop.
    ///
    /// This replaced the hands-off guard, which tried to work out from the
    /// event stream whether the person wanted Moe to stop. It could not:
    /// cua-driver's foreground input is "a genuine HID key transition" by
    /// design, indistinguishable from a hand, so every threshold fired on Moe
    /// instead. A person pressing stop is not an inference.
    public var offersStop: Bool { self == .driving }

    /// The words on the stop, by what it stops. Short enough for a chip on
    /// the notch, and named, because "Stop" alone was reported as not
    /// findable: the person is looking for the thing they want to end, and
    /// the thing has a name.
    public static func stopLabel(screen: Bool) -> String {
        screen ? "End computer use" : "End browser use"
    }
}
