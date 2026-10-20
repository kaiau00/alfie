import AppKit
import SwiftUI
import LocalAuthentication
import MoeScreen

// MARK: - Only a person can press this (D9.14)
//
// Moe drives the screen (docs/COMPUTER-USE.md): cua-driver clicks by
// accessibility press and by posting CGEvents, and AppleScript presses
// buttons through System Events. So a control that records consent — the
// consent sheet's Agree, the re-accept Agree, the Privacy switches — acts on
// its own only for an event a person made; for anything else it asks the
// person to authenticate (Touch ID / login password) before it runs.
// `HumanEventRule` (MoeScreen) is the rule and its measurements; this file
// reads the live event, keeps the person-event monitor, and wraps it for
// SwiftUI.
//
// Match on what the event IS, and prove it belongs to THIS press. Never on
// which tool might have sent it: the next tool has a new name, and a
// synthetic event from it is stamped with its pid exactly like the ones
// measured here.

/// Remembers the last event a person actually made, so a control can tell a
/// live person-press from a lingering `NSApp.currentEvent`. Process-global,
/// like the event stream it watches.
@MainActor
final class HumanPresence {
    static let shared = HumanPresence()

    private var monitor: Any?
    private var lastPersonTimestamp: TimeInterval?
    private var consumed: Set<TimeInterval> = []

    /// Install the monitor once, at launch. Idempotent.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
            self?.note(event); return event
        }
    }

    private func note(_ event: NSEvent) {
        // Only a person's event (pid 0) is worth remembering. A synthetic
        // event carries the posting process's pid and is ignored here, so it
        // can never become the "live person event" a press is matched to.
        let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        guard pid == 0 else { return }
        lastPersonTimestamp = event.timestamp
    }

    /// Mark the current event as having authorised an action, so the same
    /// event cannot authorise a second (an AX press moments after a real
    /// click).
    private func consume(_ timestamp: TimeInterval) {
        consumed.insert(timestamp)
        if consumed.count > 128 { consumed.removeAll() }   // unbounded only in theory
    }

    /// The verdict on the event dispatching right now, for a control at
    /// `frameInWindow` (SwiftUI `.global` space: window content, top-left
    /// origin, y down). Call synchronously inside the action — after an
    /// `await`, `currentEvent` is somebody else's.
    func classify(control frameInWindow: CGRect?,
                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> HumanEventRule.Verdict {
        guard let event = NSApp.currentEvent else { return HumanEventRule.classify(nil) }
        let kind: HumanEventRule.Facts.Kind
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .mouseUp
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: kind = .other
        }
        let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        let live = (lastPersonTimestamp == event.timestamp) && !consumed.contains(event.timestamp)

        let facts = HumanEventRule.Facts(
            kind: kind, sourcePID: pid, age: now - event.timestamp,
            liveAndUnused: live,
            insideControl: hitTests(event, frameInWindow: frameInWindow),
            activatesControl: activates(event))
        let verdict = HumanEventRule.classify(facts)
        if verdict.isPerson { consume(event.timestamp) }
        return verdict
    }

    private func hitTests(_ event: NSEvent, frameInWindow: CGRect?) -> Bool {
        guard let frame = frameInWindow,
              let height = event.window?.contentView?.bounds.height else { return false }
        // locationInWindow is bottom-left, y up; SwiftUI `.global` is
        // top-left, y down. Flip y to compare.
        let loc = event.locationInWindow
        return frame.contains(CGPoint(x: loc.x, y: height - loc.y))
    }

    private func activates(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.window?.isKeyWindow == true else { return false }
        switch event.keyCode {
        case 36, 76, 49: return true   // Return, keypad Enter, Space
        default: return false
        }
    }
}

enum HumanEvent {
    /// The verdict for the control at `frameInWindow`, right now.
    @MainActor
    static func current(control frameInWindow: CGRect?) -> HumanEventRule.Verdict {
        HumanPresence.shared.classify(control: frameInWindow)
    }

    /// Gate a consent action that is NOT a plain SwiftUI control — key
    /// registration (D9.14 point 4), say — the same way `HumanOnlyButton`
    /// gates a button: run only for a person's press, or after the person
    /// authenticates. Returns whether to proceed.
    @MainActor
    static func authorize(control: String, frameInWindow: CGRect? = nil,
                          reason: String = HumanOnly.authReason,
                          authenticator: PersonAuthenticator = LocalAuthAuthenticator()) async -> Bool {
        let verdict = current(control: frameInWindow)
        if verdict.isPerson { return true }
        Log.write("consent: '\(control)' not a person's press — \(verdict.reason); asking to authenticate")
        return await authenticator.confirmPerson(reason: reason)
    }
}

enum HumanOnly {
    /// Shown under a control after an attempt that was neither a person's
    /// press nor an authentication.
    static let note = "Please click this yourself."
    /// The reason string LocalAuthentication shows.
    static let authReason = "Confirm it's you to agree"
}

/// LocalAuthentication: Touch ID, then the login password. The agent can
/// drive neither.
struct LocalAuthAuthenticator: PersonAuthenticator {
    let reasonFallback = HumanOnly.authReason
    func confirmPerson(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Log.write("consent: cannot ask for authentication: \(error?.localizedDescription ?? "unknown")")
            return false
        }
        return await withCheckedContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }
}

/// A Button that runs `action` only for a person's press, or — for a press
/// that is not provably a person's (an accessibility user, say) — after the
/// person authenticates. Anything the agent can do (AX press, posted event,
/// a lingering click elsewhere) neither runs it nor gets asked.
///
///     HumanOnlyButton("Agree and continue", control: "upgrade-agree") { agree() }
///         .keyboardShortcut(.defaultAction)
struct HumanOnlyButton<Label: View>: View {
    let control: String
    let action: () -> Void
    let authenticator: PersonAuthenticator
    let label: () -> Label
    @State private var frameInWindow: CGRect?
    @State private var refused = false

    init(control: String, authenticator: PersonAuthenticator = LocalAuthAuthenticator(),
         action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.control = control
        self.authenticator = authenticator
        self.action = action
        self.label = label
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                gate(HumanEvent.current(control: frameInWindow))
            } label: { label() }
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { frameInWindow = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { frameInWindow = $0 }
            })
            if refused {
                Text(HumanOnly.note).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("human-only-note")
            }
        }
    }

    private func gate(_ verdict: HumanEventRule.Verdict) {
        if verdict.isPerson { refused = false; action(); return }
        Log.write("consent: '\(control)' not a person's press — \(verdict.reason); asking to authenticate")
        Task { @MainActor in
            if await authenticator.confirmPerson(reason: HumanOnly.authReason) {
                refused = false; action()
            } else {
                refused = true
                Log.write("consent: '\(control)' not authenticated; refused")
            }
        }
    }
}

extension HumanOnlyButton where Label == Text {
    init(_ title: String, control: String,
         authenticator: PersonAuthenticator = LocalAuthAuthenticator(), action: @escaping () -> Void) {
        self.init(control: control, authenticator: authenticator, action: action) { Text(title) }
    }
}

/// A Toggle binding whose *set* goes through only for a person's press, or
/// after the person authenticates. A refused flip leaves the value unchanged
/// (SwiftUI re-reads it, so the switch springs back). Give the Toggle a
/// `GeometryReader` background that writes `frame` so the hit-test works;
/// `PrivacyToggleRow` (integration) does this.
extension Binding where Value == Bool {
    @MainActor
    func humanOnly(_ control: String, frame: CGRect?, refused: Binding<Bool>,
                   authenticator: PersonAuthenticator = LocalAuthAuthenticator()) -> Binding<Bool> {
        Binding(get: { wrappedValue }, set: { new in
            guard new != wrappedValue else { return }
            let verdict = HumanEvent.current(control: frame)
            if verdict.isPerson { refused.wrappedValue = false; wrappedValue = new; return }
            Log.write("consent: '\(control)' not a person's press — \(verdict.reason); asking to authenticate")
            Task { @MainActor in
                if await authenticator.confirmPerson(reason: HumanOnly.authReason) {
                    refused.wrappedValue = false; wrappedValue = new
                } else {
                    refused.wrappedValue = true
                }
            }
        })
    }
}
