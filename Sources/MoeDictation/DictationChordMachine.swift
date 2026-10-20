import Foundation

/// The dictation key's tap grammar, with no clock and no AppKit in it.
///
/// Hold: press, speak, release — recording runs for exactly as long as the
/// key is down. Double-tap: two quick taps latch dictation on with nothing
/// held, for when both hands are needed elsewhere; the next tap (or Esc)
/// ends it. `PushToTalk` feeds this the key's flag transitions and carries
/// out the actions it hands back; the timing rules live here so they can
/// be tested without a keyboard.
///
/// Times are seconds on any monotonic clock; only differences matter.
public struct DictationChordMachine: Equatable {

    public enum Event: Equatable {
        /// The dictation key went down / came up, on its own.
        case down(Double)
        case up(Double)
        /// Another key went down while the dictation key is held: it is a
        /// shortcut (right ⌘ then C), not dictation. Ignored while latched —
        /// nothing is held, so nothing can be a shortcut.
        case otherKey
        case esc
        /// The clock, for the latch timeout. Harmless at any other time.
        case tick(Double)
        /// The screen locked or the Mac is going to sleep.
        case lock
    }

    public enum UnlatchReason: String, Equatable {
        case tap, esc, timeout, lock
    }

    public enum Action: Equatable {
        /// Start recording.
        case begin
        /// Stop recording and type what was said.
        case end
        /// Stop recording and type nothing.
        case cancel
        /// Recording continues with no key held (it is already running).
        case latch
        /// The hands-free run is over; an `end` or `cancel` follows.
        case unlatch(UnlatchReason)
    }

    public enum Phase: Equatable {
        case idle
        /// Key down, recording; a tap or a hold — not known until release.
        case held(since: Double)
        /// Recording with nothing held.
        case latched(since: Double)
        /// Key down again while latched: its release ends the run.
        case latchedKeyDown(since: Double)
    }

    /// A press shorter than this is a tap, not a hold. Same as the agent
    /// chord's.
    public let tapThreshold: Double
    /// Two taps closer together than this (release to release) latch.
    public let doubleTapWindow: Double
    /// Latched dictation ends on its own after this long: a run left on by
    /// mistake must not sit with the microphone open all afternoon.
    public let latchTimeout: Double

    public private(set) var phase: Phase = .idle
    /// When the last tap was released, if the next tap could pair with it.
    private var lastTapUp: Double?

    public init(tapThreshold: Double = 0.22,
                doubleTapWindow: Double = 0.35,
                latchTimeout: Double = 180) {
        self.tapThreshold = tapThreshold
        self.doubleTapWindow = doubleTapWindow
        self.latchTimeout = latchTimeout
    }

    public var isLatched: Bool {
        switch phase {
        case .latched, .latchedKeyDown: return true
        case .idle, .held: return false
        }
    }

    /// Recording is running, whether held or latched.
    public var isActive: Bool { phase != .idle }

    /// When the latch will time out, for whoever owns the timer.
    public var latchDeadline: Double? {
        switch phase {
        case .latched(let since), .latchedKeyDown(let since): return since + latchTimeout
        case .idle, .held: return nil
        }
    }

    /// Feed one event; do the actions in the order returned.
    public mutating func handle(_ event: Event) -> [Action] {
        switch (phase, event) {

        // MARK: Hold-to-talk

        case (.idle, .down(let t)):
            phase = .held(since: t)
            return [.begin]

        case (.held(let since), .up(let t)):
            phase = .idle
            let held = t - since
            guard held < tapThreshold else {
                // A real hold: it stands alone, and a tap after it is a
                // fresh first tap.
                lastTapUp = nil
                return [.end]
            }
            if let last = lastTapUp, t - last < doubleTapWindow {
                // Second tap of two: the recording this tap started stays
                // on. Whatever the first tap heard was already typed (or,
                // more likely, was too short to be anything).
                lastTapUp = nil
                phase = .latched(since: t)
                return [.latch]
            }
            lastTapUp = t
            return [.end]

        case (.held, .otherKey):
            phase = .idle
            lastTapUp = nil
            return [.cancel]

        case (.held, .esc):
            phase = .idle
            lastTapUp = nil
            return [.cancel]

        // Lock/sleep: drop what was heard. Ending would paste it into
        // whatever has focus after the unlock, which is never what was meant.
        case (.held, .lock):
            phase = .idle
            lastTapUp = nil
            return [.cancel]

        // MARK: Latched

        case (.latched(let since), .down):
            phase = .latchedKeyDown(since: since)
            return []

        case (.latchedKeyDown, .up):
            // Tap or hold, either ends it: the key was pressed on purpose,
            // and the run is over. Never a second latch.
            phase = .idle
            lastTapUp = nil
            return [.unlatch(.tap), .end]

        case (.latched, .esc), (.latchedKeyDown, .esc):
            phase = .idle
            lastTapUp = nil
            return [.unlatch(.esc), .cancel]

        case (.latched, .otherKey):
            // Hands-free means the keyboard is free: typing, ⌘Tab, a
            // scroll — none of it is a shortcut on top of the dictation key.
            return []

        case (.latchedKeyDown(let since), .otherKey):
            // The key was down for a shortcut (right ⌘ then Tab, or C), not
            // to finish: the run carries on, and the release that follows
            // must not end it — ⌘Tab would otherwise paste into the app
            // just switched to.
            phase = .latched(since: since)
            return []

        case (.latched(let since), .tick(let t)), (.latchedKeyDown(let since), .tick(let t)):
            guard t - since >= latchTimeout else { return [] }
            phase = .idle
            lastTapUp = nil
            return [.unlatch(.timeout), .end]

        case (.latched, .lock), (.latchedKeyDown, .lock):
            phase = .idle
            lastTapUp = nil
            return [.unlatch(.lock), .cancel]

        // MARK: Nothing to do

        case (.idle, .up), (.idle, .otherKey), (.idle, .esc), (.idle, .tick), (.idle, .lock),
             (.held, .down), (.held, .tick),
             (.latched, .up), (.latchedKeyDown, .down):
            return []
        }
    }

    /// Forget everything: the tap was re-armed, or the recording was taken
    /// down by something other than the key.
    public mutating func reset() {
        phase = .idle
        lastTapUp = nil
    }
}
