import Foundation

/// Did a person make the event that is triggering this control? (D9.14)
///
/// The rule, in the terms the event itself carries — never a list of tools
/// that might have sent it (CLAUDE.md: a guard that enumerates names is
/// walked past by a new name). Measured 2026-09-11 on an M3, macOS 26.5.2,
/// against a standalone SwiftUI harness, reading `NSApp.currentEvent` inside
/// the Button/Toggle action:
///
/// (The person rows: the owner's own clicks on the harness window,
/// 2026-09-11 09:12:13–19Z, five pairs, age 2–18 ms; and 316 keyDowns and
/// every trackpad mouse-down seen by a listen-only tap over 150 s — all
/// `sourcePID` 0, user 0. Every synthetic row below carried user 501.)
///
/// | route                                      | currentEvent | sourcePID | user | age |
/// |--------------------------------------------|--------------|-----------|------|-----|
/// | a person's click (trackpad), a person's key| mouse/key    | **0**     | 0    | ms  |
/// | AXPress (`AXUIElementPerformAction`)       | **nil**      | —         | —    | —   |
/// | cua-driver `click` by element (AX path)    | **nil**      | —         | —    | —   |
/// | another process's `postToPid` Return — it FIRED a default button | keyDown | **poster's pid** | 501 | ms |
/// | cua-driver `click` by pixel (CGEvent path) | mouse        | **cua's pid** | 501 | **timestamp 0** |
///
/// `sourceStateID` is 1 (HID system state) for *all* of them, so it cannot
/// tell a person from a poster, and is not used. What separates them:
///
/// 1. **the source process** — a synthetic event is stamped with the posting
///    process's pid; a hardware event carries 0. An accessibility press has
///    no event at all.
/// 2. **liveness** — `NSApp.currentEvent` is process-global and an AX press
///    does not clear it, so a person's click *elsewhere* can still be the
///    current event when the agent presses this control a second later. So a
///    live person-event monitor must have seen *this exact* event as a
///    person's (pid 0), and it must not already have authorised an action
///    (`liveAndUnused`). This is what stops a lingering event riding a press.
/// 3. **delivery to THIS control** — a mouse-up must land inside the control
///    (`insideControl`); a key must be Return/Space with the control's window
///    key and the control the active one (`activatesControl`). A person who
///    clicked elsewhere fails this even if 1 and 2 somehow held.
///
/// When the verdict is not `.person`, the caller does not simply refuse: it
/// asks for the person with LocalAuthentication (`HumanGate`), so VoiceOver,
/// Voice Control and Switch users — whose presses are accessibility presses —
/// can still agree, while the agent, which cannot pass Touch ID or the login
/// password, cannot.
public enum HumanEventRule {

    /// What the app could read about the triggering event.
    public struct Facts: Equatable, Sendable {
        public enum Kind: String, Sendable { case mouseDown, mouseUp, keyDown, keyUp, other }
        public var kind: Kind
        /// `CGEventField.eventSourceUnixProcessID`. 0 for hardware, and -1
        /// stands in for an input event with no CGEvent (also not a person).
        public var sourcePID: Int64
        /// Seconds between the event's timestamp and now (system uptime).
        public var age: TimeInterval
        /// A live monitor saw THIS event as a person's (pid 0) and it has
        /// not authorised an action before.
        public var liveAndUnused: Bool
        /// mouseUp: the event's location is inside this control. (Ignored
        /// for keys.)
        public var insideControl: Bool
        /// keyDown: it is Return or Space, the control's window is key, and
        /// the control is the active one. (Ignored for mouse.)
        public var activatesControl: Bool
        public init(kind: Kind, sourcePID: Int64, age: TimeInterval,
                    liveAndUnused: Bool, insideControl: Bool, activatesControl: Bool) {
            self.kind = kind; self.sourcePID = sourcePID; self.age = age
            self.liveAndUnused = liveAndUnused
            self.insideControl = insideControl; self.activatesControl = activatesControl
        }
    }

    public enum Verdict: Equatable, Sendable {
        case person
        /// No event: an accessibility press, or code calling the action.
        case noEvent
        /// Not the mouse-up or key-down an action fires on.
        case notInput(String)
        /// Stamped with a posting process: synthetic.
        case posted(pid: Int64)
        /// Older than any press it could have caused, or dated in the future.
        case stale(TimeInterval)
        /// Not the live, unused person event this dispatch should carry — a
        /// lingering `currentEvent`, or one already used.
        case notLive
        /// A mouse-up outside this control (a click elsewhere).
        case outsideControl
        /// A key that does not activate this control.
        case notActivating

        public var isPerson: Bool { self == .person }

        /// One line for the log. Never shown to the person.
        public var reason: String {
            switch self {
            case .person: return "person"
            case .noEvent: return "no triggering event (accessibility press or programmatic)"
            case .notInput(let k): return "triggering event is not a mouse-up or key-down (\(k))"
            case .posted(let pid): return "synthetic event posted by pid \(pid)"
            case .stale(let age): return String(format: "triggering event is %.2f s old", age)
            case .notLive: return "not the live, unused person event for this press (a lingering or reused event)"
            case .outsideControl: return "the click was not inside this control"
            case .notActivating: return "the key does not activate this control"
            }
        }
    }

    /// Longest a press may take between the event and the action running. A
    /// real click's action runs within milliseconds of its mouse-up; 0.5 s is
    /// generous and still far shorter than a person could notice a lingering
    /// event surviving.
    public static let maxAge: TimeInterval = 0.5
    /// A little slack for clock jitter; anything more in the future is not a
    /// press that just happened.
    public static let ageFloor: TimeInterval = -0.05

    public static func classify(_ facts: Facts?) -> Verdict {
        guard let f = facts else { return .noEvent }
        switch f.kind {
        case .mouseUp, .keyDown: break
        default: return .notInput(f.kind.rawValue)
        }
        guard f.sourcePID == 0 else { return .posted(pid: f.sourcePID) }
        guard f.age >= ageFloor, f.age <= maxAge else { return .stale(f.age) }
        guard f.liveAndUnused else { return .notLive }
        switch f.kind {
        case .mouseUp: return f.insideControl ? .person : .outsideControl
        case .keyDown: return f.activatesControl ? .person : .notActivating
        default: return .notInput(f.kind.rawValue)
        }
    }
}

// MARK: - The accessibility fallback (D9.14)

/// Proves the person is there when the triggering event did not (VoiceOver,
/// Voice Control, Switch Control — their presses are accessibility presses,
/// which carry no event). The real one is Touch ID / the login password via
/// LocalAuthentication; tests inject a stub so nothing prompts.
public protocol PersonAuthenticator: Sendable {
    /// `true` if the person authenticated. Never throws — a cancel or a
    /// missing biometric is just `false`.
    func confirmPerson(reason: String) async -> Bool
}

/// Person's press → run. Otherwise ask the person to authenticate, and run
/// only if they do. The agent cannot pass either gate.
public enum HumanGate {
    public static func allow(_ verdict: HumanEventRule.Verdict,
                             reason: String,
                             authenticator: PersonAuthenticator) async -> Bool {
        if verdict.isPerson { return true }
        return await authenticator.confirmPerson(reason: reason)
    }
}

/// For tests, and for the harness (so the falsifier never triggers Touch ID).
public struct DenyingAuthenticator: PersonAuthenticator {
    public init() {}
    public func confirmPerson(reason: String) async -> Bool { false }
}
public struct AllowingAuthenticator: PersonAuthenticator {
    public init() {}
    public func confirmPerson(reason: String) async -> Bool { true }
}
