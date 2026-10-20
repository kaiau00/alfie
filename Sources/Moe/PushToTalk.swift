import AppKit
import Carbon.HIToolbox
import MoeDictation
import MoeErase

/// Hold-to-talk on a bare modifier chord (⌃⌥ by default).
///
/// Modelled on farzaa/clicky (MIT), which ships this and nothing else — no wake
/// word, no voice-activity detection. A held key is the only turn-taking signal
/// that never guesses wrong: recording starts when you press and ends when you
/// let go. Every failure Moe had — triggering on its own voice, cutting people
/// off, transcribing the room — came from trying to infer what a key press
/// states outright.
///
/// It uses a listen-only `CGEvent` tap rather than `NSEvent`'s global monitor,
/// because bare modifier chords are unreliable through AppKit's monitors. The
/// tap needs Accessibility permission and re-arms itself when macOS disables it
/// for being slow.
///
/// The one tap watches two chords: the talk key for the agent ("do what I
/// said") — right ⌥ unless Settings says otherwise (`TalkKey`) — and, by
/// default, right ⌘ for dictation ("type what I said"). Each chord is only
/// ever *down* when its key is the sole modifier held, so the two can never
/// be active at once and nothing has to guess which one you meant. When both
/// would be the same key, dictation is handed `.off` (`Conductor`).
///
/// The dictation key also has a double-tap: two quick taps latch dictation
/// on with nothing held, and the next tap (or Esc) ends it. That grammar is
/// `DictationChordMachine`; this class only turns flag changes into its
/// events and its actions into callbacks. The talk key has the same
/// hands-free latch when Moe is idle — the next tap sends the turn — and
/// keeps double-tap as "stop everything" otherwise (`TalkChordMachine`).
@MainActor
final class PushToTalk {

    /// Fired when the key goes down, and again when it comes up.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// A tap's release: the press was never a turn. Unset, it is a release.
    var onTap: (() -> Void)?
    /// Two quick taps that did not latch: stop everything.
    var onDoubleTap: (() -> Void)?
    /// Asked at a double-tap: should it listen hands-free instead of
    /// stopping? True only with Moe idle (`Conductor.talkLatchAllowed`).
    /// Unset, every double-tap stops, as it always did.
    var talkLatchAllowed: (() -> Bool)?
    /// The press has been down for a tap's length: it is a hold, not a tap.
    /// Until this a press from rest shows nothing (`Conductor.holdConfirmed`).
    var onHoldConfirmed: (() -> Void)?
    /// Hands-free listening on the talk key began / ended. Unlatch is
    /// always followed by a release (send) or a cancel (drop).
    var onTalkLatch: (() -> Void)?
    var onTalkUnlatch: ((TalkChordMachine.UnlatchReason) -> Void)?
    /// Fired instead of a release when the held key turns out to be part of
    /// a shortcut — another key went down while it was held (fn+Delete,
    /// right ⌘+Tab, right ⌥+←). `onPress` has already fired; whatever it
    /// started must be taken down without a turn (`Conductor.holdCancelled`).
    /// Unset, a cancel falls back to `onRelease`, so a hold can never be
    /// left open with the microphone live.
    var onCancel: (() -> Void)?

    /// The dictation chord. Cancel fires instead of release when the held key
    /// turns out to be part of a shortcut (right ⌘ then C is a copy, not a
    /// request to type something).
    var onDictationPress: (() -> Void)?
    var onDictationRelease: (() -> Void)?
    var onDictationCancel: (() -> Void)?
    /// Double-tapped: recording carries on with nothing held. Unlatch is
    /// always followed by a release or a cancel.
    var onDictationLatch: (() -> Void)?
    var onDictationUnlatch: ((DictationChordMachine.UnlatchReason) -> Void)?

    /// Which key dictates. `.off` disarms that chord; the agent chord is
    /// unaffected. Settable while the tap is live, so Settings applies at once.
    var dictationKey: DictationKey = .rightCommand {
        didSet { if dictationKey != oldValue { abandonDictation() } }
    }

    /// Which key you hold to talk. Settable while the tap is live, so
    /// Settings applies at once: a hold in progress on the old key ends at
    /// the next flag change, because the new key is not down.
    var talkKey: TalkKey = .rightOption

    var isDictationLatched: Bool { dictation.isLatched }
    var isTalkLatched: Bool { talk.isLatched }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The talk key's grammar — press, release, tap, double-tap, and a
    /// press that became a shortcut. The timing rules live there.
    private var talk = TalkChordMachine(tapThreshold: 0.22, doubleTapWindow: 0.35)
    /// The timer for a tap's held-back release (`TalkChordMachine`).
    private var tapWindow: DispatchWorkItem?
    /// The timer that says a press has lasted longer than a tap.
    private var holdTimer: DispatchWorkItem?
    /// The dictation grammar, and whether its key is physically down (so a
    /// stream of flag changes becomes one down and one up).
    private var dictation = DictationChordMachine(tapThreshold: 0.22, doubleTapWindow: 0.35,
                                                  latchTimeout: 180)
    private var dictationKeyDown = false
    private var latchTimer: Timer?
    private var lockObservers: [NSObjectProtocol] = []
    private var dictationDown: Bool { dictation.isActive }

    /// The talk key, on its own: its device-dependent bit is set and no
    /// other modifier is held — ⌘⌥, ⌃⌥ and friends belong to other apps.
    ///
    /// Right ⌥ by default because almost nothing else uses it: the left one
    /// appears in plenty of shortcuts and in Option-key character entry, while
    /// the right one is nearly always idle. macOS reports the two sides
    /// separately in the device-dependent flag bits, which is the only way to
    /// tell them apart — `.maskAlternate` is set by both. For right ⌥ the
    /// "others" are exactly ⌘, ⌃ and ⇧, as they always were; for any other
    /// key ⌥ joins them and the key's own modifier leaves.
    nonisolated static func isCleanPress(_ flags: CGEventFlags, of key: TalkKey) -> Bool {
        let held = (flags.rawValue & key.flagBit) != 0
        var others: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
        others.remove(key.genericFlag)
        return held && flags.intersection(others).isEmpty
    }

    init() {}

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    private static let askedKey = "moe.accessibilityAskedAt"

    static func requestAccessibility() {
        UserDefaults.standard.set(Date(), forKey: askedKey)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Moe has asked before and macOS still says no. Either the person
    /// declined — or, far more confusing, System Settings shows Moe switched
    /// ON and it still does not work. That second one is a stale grant: the
    /// toggle belongs to an earlier copy of Memoe, signed differently, and
    /// macOS keeps showing it while refusing this one. On 2026-09-10 the
    /// owner's Mac held five such entries after a delete-and-redownload.
    static var askedButStillOff: Bool {
        !hasAccessibility && UserDefaults.standard.object(forKey: askedKey) != nil
    }

    /// Forget every Accessibility entry macOS holds for this app — the stale
    /// ones included — and ask again, so the toggle the person turns on is
    /// this copy's. `tccutil reset` needs no password for the caller's own
    /// bundle id (measured 2026-09-10). Only ever this app's id: resetting
    /// anything else is not ours to do.
    static func resetAccessibilityAndAsk() {
        resetAccessibilityAndAsk(bundleID: Bundle.main.bundleIdentifier,
                                 tccutil: runTccutil, askAgain: askAgain)
    }

    /// The same, with the two things it does to the Mac handed in, so a test
    /// can watch it reach `tccutil` rather than read that it would.
    static func resetAccessibilityAndAsk(bundleID: String?,
                                         tccutil: ([String]) -> Int32?,
                                         askAgain: () -> Void) {
        guard let id = tccResetTarget(bundleID: bundleID) else {
            Log.write("accessibility: not resetting — \(bundleID ?? "no bundle id") "
                      + "is not Memoe or Memoe Dev")
            return
        }
        if let status = tccutil(["reset", "Accessibility", id]) {
            Log.write("accessibility: reset \(id) (exit \(status)); asking again")
        }
        askAgain()
    }

    private static func runTccutil(_ arguments: [String]) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            Log.write("accessibility: tccutil reset failed — \(error.localizedDescription)")
            return nil
        }
    }

    private static func askAgain() {
        requestAccessibility()
        if let url = PermissionGuide.accessibility.settingsURL { NSWorkspace.shared.open(url) }
    }

    /// The identifier `tccutil reset` may be pointed at: this app's own, and
    /// only when it is one of the two identities build.sh makes
    /// (`MacEraseIdentity`, the one list of them). Nil for anything else — a
    /// bare `swift build` binary, a renamed copy — because resetting another
    /// app's grants is not ours to do.
    ///
    /// This was `id.hasPrefix("com.moe.")` until 2026-09-23. The rename to
    /// `com.memoe.app` (fcd320e9) made it false on every Mac, so "Reset and
    /// ask again" and every "Fix" button returned here and did nothing.
    nonisolated static func tccResetTarget(bundleID: String?) -> String? {
        MacEraseIdentity(bundleID: bundleID)?.bundleID
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }          // never re-arm over a live tap
        guard Self.hasAccessibility else { return false }

        // keyDown too, only so a held key — the talk key or the dictation
        // key — can tell it has become a shortcut. Nothing happens with it
        // unless one of those is down.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<PushToTalk>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // macOS switches the tap off if it ever thinks we're slow.
                Task { @MainActor in me.reArm() }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                Task { @MainActor in me.keyWentDown(code) }
                return Unmanaged.passUnretained(event)
            }
            let flags = event.flags
            Task { @MainActor in me.handle(flags) }
            return Unmanaged.passUnretained(event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,                      // never swallow the event
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        watchForLock()
        return true
    }

    /// A latched dictation or hands-free turn must not outlive the screen:
    /// the lock and the lid both end it. Dictation types what was said so
    /// far; a hands-free turn is dropped, never sent to an unattended Mac.
    private func watchForLock() {
        guard lockObservers.isEmpty else { return }
        let locked = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dictationEvent(.lock); self?.talkLocked() }
        }
        let sleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dictationEvent(.lock); self?.talkLocked() }
        }
        lockObservers = [locked, sleep]
    }

    private func reArm() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        // Anything that happened while the tap was off is gone, and a release
        // among it would leave the dictation hold stuck open with the mic
        // live — and the next flags event would then paste whatever was heard
        // meanwhile. If the key is no longer physically down, drop the hold;
        // if it still is, the hold is genuine and carries on.
        // (Dictation only: the agent chord is left exactly as it was.)
        // A latched run has nothing held, so a missed release costs it
        // nothing; only a plain hold is dropped.
        if dictationKeyDown, !dictation.isLatched, let bit = dictationKey.flagBit,
           CGEventSource.flagsState(.combinedSessionState).rawValue & bit == 0 {
            // The key is up, so say so — or the next press would be read
            // as still part of the missed one and swallowed.
            dictationKeyDown = false
            abandonDictation()
        }
    }

    private func handle(_ flags: CGEventFlags) {
        handleAgent(flags)
        handleDictation(flags)
    }

    /// The agent chord. Unchanged by dictation: its "nothing else held" test
    /// already covers ⌘ and ⌃, so pressing the dictation key while this is
    /// down releases it, and holding both starts neither.
    private func handleAgent(_ flags: CGEventFlags) {
        let pressed = Self.isCleanPress(flags, of: talkKey)
        if pressed && !talk.isDown {
            runTalk(talk.handle(.down(Self.now)))
            armHoldTimer()
        } else if !pressed && talk.isDown {
            holdTimer?.cancel(); holdTimer = nil
            runTalk(talk.handle(.up(Self.now)))
        }
    }

    /// A press that is still down after `tapThreshold` is a hold. Re-armed
    /// on every press, so the first tap of a double-tap can never confirm
    /// the second press early; the machine checks the time as well.
    private func armHoldTimer() {
        holdTimer?.cancel(); holdTimer = nil
        guard talk.holdConfirmPending else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.holdTimer = nil
            self.runTalk(self.talk.handle(.holdThreshold(Self.now)))
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + talk.tapThreshold, execute: work)
    }

    /// A real key went down. For a held talk key that makes it a shortcut
    /// (every talk key — a chord is never a talk press); for dictation, a
    /// shortcut or, for Esc, stop. The modifiers' own key codes are ignored:
    /// they arrive as flag changes, and a stray one must not cancel a hold.
    private func keyWentDown(_ code: Int64) {
        guard !Self.isModifierKeyCode(code) else { return }
        let esc = code == Int64(kVK_Escape)
        dictationEvent(esc ? .esc : .otherKey)
        runTalk(talk.handle(esc ? .esc : .otherKey))
    }

    private func talkLocked() {
        runTalk(talk.handle(.lock))
    }

    /// The hands-free turn ended on the other side (a stop-all, the voice
    /// leaving the recording). Forget the latch so the next tap is a fresh
    /// press, not a "send" for a turn that no longer exists.
    func talkLatchWasAbandoned() {
        guard talk.isLatched else { return }
        tapWindow?.cancel()
        tapWindow = nil
        talk.reset()
    }

    nonisolated static func isModifierKeyCode(_ code: Int64) -> Bool {
        [kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
         kVK_Control, kVK_RightControl, kVK_Function, kVK_CapsLock].contains(Int(code))
    }

    private func runTalk(_ actions: [TalkChordMachine.Action]) {
        for action in actions {
            switch action {
            case .press:     onPress?()
            case .release:   onRelease?()
            case .tap:       if let onTap { onTap() } else { onRelease?() }
            case .doubleTap:
                // Idle: listen hands-free. Anything else — or a latch the
                // machine refuses — is the stop it has always been.
                let latched = talkLatchAllowed?() == true ? talk.handle(.latch) : []
                if latched.isEmpty { onDoubleTap?() } else { runTalk(latched) }
            case .latch:     onTalkLatch?()
            case .unlatch(let reason): onTalkUnlatch?(reason)
            case .holdConfirmed: onHoldConfirmed?()
            case .cancel:
                if let onCancel { onCancel() } else { onRelease?() }
            case .armTapWindow:
                tapWindow?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.tapWindow = nil
                    self.runTalk(self.talk.handle(.tapWindowClosed))
                }
                tapWindow = work
                DispatchQueue.main.asyncAfter(deadline: .now() + talk.doubleTapWindow, execute: work)
            case .disarmTapWindow:
                tapWindow?.cancel()
                tapWindow = nil
            }
        }
    }

    /// The dictation chord: its key alone, with no other modifier — ⌥
    /// included, so it can never coincide with the agent chord.
    private func handleDictation(_ flags: CGEventFlags) {
        guard let bit = dictationKey.flagBit else { return }
        let keyHeld = (flags.rawValue & bit) != 0
        var others: CGEventFlags = [.maskCommand, .maskControl, .maskShift,
                                    .maskAlternate, .maskSecondaryFn]
        others.remove(dictationKey.genericFlag)
        let clean = flags.intersection(others).isEmpty

        if keyHeld && clean && !dictationKeyDown {
            dictationKeyDown = true
            run(dictation.handle(.down(Self.now)))
        } else if keyHeld && !clean && dictationKeyDown {
            // A second modifier joined: ⌘⇧… is a shortcut on its way, not the
            // end of a dictation. Cancel rather than release — releasing here
            // would paste into the app while the user still holds ⌘, and the
            // shortcut would then land on top of the pasted text. (While
            // latched the machine lets it pass: nothing was being held.)
            run(dictation.handle(.otherKey))
        } else if !keyHeld && dictationKeyDown {
            dictationKeyDown = false
            run(dictation.handle(.up(Self.now)))
        }
    }

    /// A real key while the dictation modifier is held means a shortcut, not
    /// dictation; Esc while latched means stop and type nothing. Cheap when
    /// nothing is going on — the machine answers with no actions.
    private func dictationEvent(_ event: DictationChordMachine.Event) {
        guard dictationDown else { return }
        run(dictation.handle(event))
    }

    /// Something other than the key took the recording down (Settings
    /// changed the key, the tap was re-armed over a stale hold). Type nothing.
    private func abandonDictation() {
        guard dictationDown else { return }
        let wasLatched = dictation.isLatched
        dictation.reset()
        armLatchTimer()
        if wasLatched { onDictationUnlatch?(.esc) }
        onDictationCancel?()
    }

    /// The recording ended on the other side (× on the island, a stop-all).
    /// Forget the hold so nothing is typed when the key next moves.
    func dictationWasAbandoned() {
        guard dictationDown else { return }
        let wasLatched = dictation.isLatched
        dictation.reset()
        armLatchTimer()
        if wasLatched { onDictationUnlatch?(.esc) }
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private func run(_ actions: [DictationChordMachine.Action]) {
        for action in actions {
            switch action {
            case .begin:  onDictationPress?()
            case .end:    onDictationRelease?()
            case .cancel: onDictationCancel?()
            case .latch:  onDictationLatch?()
            case .unlatch(let reason): onDictationUnlatch?(reason)
            }
        }
        armLatchTimer()
    }

    /// One timer, live only while latched, that fires at the deadline.
    private func armLatchTimer() {
        latchTimer?.invalidate(); latchTimer = nil
        guard let deadline = dictation.latchDeadline else { return }
        let wait = max(0, deadline - Self.now)
        latchTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.run(self.dictation.handle(.tick(Self.now)))
            }
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        talk.reset()
        tapWindow?.cancel()
        tapWindow = nil
        holdTimer?.cancel()
        holdTimer = nil
        dictationKeyDown = false
        dictation.reset()
        armLatchTimer()
        for o in lockObservers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        lockObservers = []
    }
}


/// The talk key's grammar, with no clock and no AppKit in it — the agent
/// chord's counterpart to `DictationChordMachine`. `PushToTalk` feeds it the
/// key's clean-press transitions and every real key that goes down, and
/// carries out what it hands back.
///
/// - Hold: `press` on the way down, `release` on the way up.
/// - Tap (shorter than `tapThreshold`): the release is held back for
///   `doubleTapWindow` (`armTapWindow`), and delivered when the window closes
///   if nothing follows. Before that hold-back, the first tap of a double-tap
///   paused the reply, lit the island, took a screenshot and resumed the
///   reply, all inside the window in which the second tap stopped everything
///   (2026-09-06).
/// - Double-tap: down again inside the window, and up again quickly —
///   `doubleTap`. The first tap's press is still standing; no second press.
///   What a double-tap means is not the machine's to say: over a reply or
///   a turn in progress it stops everything, and with Moe idle it latches
///   hands-free listening. The owner answers, and feeds `.latch` back when
///   it latched.
/// - Hands-free (latched): the press the first tap made stays open with
///   nothing held — the microphone carries on recording the turn. The next
///   press of the key, tap or hold, ends it: `unlatch(.tap)` then `release`,
///   exactly what letting go of a held press does, so the turn is sent the
///   same way. Silence never ends it. Esc, or the screen locking, ends it
///   with `cancel` instead: nothing is sent. Other keys are free while
///   latched — hands-free means the keyboard is too — and a key that goes
///   down while the talk key is down makes that press a shortcut, which
///   leaves the run going. A tap within `quickUndoWindow` of the latch is
///   not "send" but "never mind": a triple-tap meant stop, and on 2026-10-13
///   the third tap of one sent eight stray words to the brain. It cancels.
///   A press that starts within `doubleTapWindow` of
///   the tap that sent is swallowed whole: double-tapping to finish would
///   otherwise open a new hold over the turn just sent, and a press while a
///   turn is being read back throws its answer away.
/// - Shortcut: a real key goes down while the talk key is held — fn+Delete,
///   right ⌘+Tab, right ⌥+← — so it was never a talk press. `cancel` instead
///   of a release; the release that follows does nothing, and the press
///   earns no double-tap credit, so two quick chords are two cancels, never
///   a stop. With right ⌥ this was rare; fn and right ⌘ are in shortcuts all
///   day.
///
/// Times are seconds on any monotonic clock; only differences matter.
struct TalkChordMachine: Equatable {

    enum Event: Equatable {
        /// The talk key went down / came up, on its own.
        case down(Double)
        case up(Double)
        /// Any non-modifier key other than Esc went down.
        case otherKey
        /// Esc went down. While a press is held it is a shortcut like any
        /// other key; while latched it drops the turn.
        case esc
        /// The double-tap window armed by `armTapWindow` ran out.
        case tapWindowClosed
        /// The owner took the `doubleTap` just handed back as "listen
        /// hands-free". Ignored unless it immediately follows one.
        case latch
        /// The screen locked or the Mac is going to sleep.
        case lock
        /// `tapThreshold` after a press went down (the owner's timer). A
        /// press still down by then is a hold, not a tap.
        case holdThreshold(Double)
    }

    enum UnlatchReason: String, Equatable {
        case tap, esc, lock
        /// A tap straight after the latch: undo it, send nothing.
        case undo
    }

    enum Action: Equatable {
        /// Start a hold (`Conductor.holdBegan`).
        case press
        /// End it: a turn (`Conductor.holdEnded`).
        case release
        /// End it: it was a tap, delivered once the double-tap window closed
        /// (`Conductor.holdTapped`). Said outright rather than left for the
        /// receiver to time: the release reaches it `doubleTapWindow` late, so
        /// every tap measured longer than the 0.3 s a tap may last, and the
        /// pause button was read as a hold — the owner, 2026-09-23: "I pressed
        /// Option while it was talking, and then it kind of loads."
        case tap
        /// Two quick taps. Stop everything, or latch (`Event.latch`).
        case doubleTap
        /// It was a shortcut, or a hands-free turn was dropped: take down
        /// what `press` started, with no turn.
        case cancel
        /// Start the double-tap window's timer; feed `.tapWindowClosed` when
        /// it fires.
        case armTapWindow
        /// The window's timer is no longer wanted.
        case disarmTapWindow
        /// Hands-free listening is on: the standing press stays open.
        case latch
        /// Hands-free listening is over; a `release` or `cancel` follows.
        case unlatch(UnlatchReason)
        /// The press standing now has outlasted a tap: show it as listening
        /// (`Conductor.holdConfirmed`). At most once per press.
        case holdConfirmed
    }

    /// A press shorter than this is a tap, not a hold. Deliberately short: a
    /// real "let me say something" press is far longer, and mistaking one
    /// for a tap is expensive.
    let tapThreshold: Double
    /// Two taps closer together than this count as a double tap.
    let doubleTapWindow: Double

    /// A tap this soon after a latch undoes it rather than sending.
    let quickUndoWindow: Double

    init(tapThreshold: Double = 0.22, doubleTapWindow: Double = 0.35, quickUndoWindow: Double = 0.8) {
        self.tapThreshold = tapThreshold
        self.doubleTapWindow = doubleTapWindow
        self.quickUndoWindow = quickUndoWindow
    }

    /// The key is physically down (as a clean press).
    private(set) var isDown = false
    private var pressedAt: Double = 0
    /// A tap's release is being held back for the window.
    private(set) var tapPending = false
    /// The key is down for the second time inside the window.
    private var secondPress = false
    /// This press became a shortcut; its release is swallowed.
    private(set) var isCancelled = false
    /// Listening hands-free: the press is open with nothing held.
    private(set) var isLatched = false
    /// The last thing handed back was a `doubleTap`, so a `.latch` may follow.
    private var doubleTapJustHappened = false
    /// A press starting before this is the tail of the gesture that sent a
    /// hands-free turn, not a new one.
    private var swallowPressesUntil: Double?
    /// The key is down for a press being swallowed.
    private var swallowing = false
    /// When the last double-tap's second release came — the latch, if the
    /// owner takes it.
    private var lastDoubleTapAt: Double?
    private var latchedAt: Double?
    /// A press is down that has not yet been confirmed as a hold.
    private(set) var holdConfirmPending = false

    /// Feed one event; do the actions in the order returned.
    mutating func handle(_ event: Event) -> [Action] {
        let mayLatch = doubleTapJustHappened
        doubleTapJustHappened = false

        switch event {
        case .down(let t):
            guard !isDown else { return [] }
            isDown = true
            pressedAt = t
            isCancelled = false
            holdConfirmPending = false
            if isLatched { return [] }     // the release says what it was
            if let until = swallowPressesUntil {
                swallowPressesUntil = nil
                if t < until {
                    swallowing = true
                    return []
                }
            }
            if tapPending {
                // Down again inside the window: the first tap's release was
                // never delivered, so the press it made is still standing.
                // Either the second half of a double-tap or a hold that began
                // with a brush of the key; the release says which.
                tapPending = false
                secondPress = true
                holdConfirmPending = true
                return [.disarmTapWindow]
            }
            holdConfirmPending = true
            return [.press]

        case .up(let t):
            guard isDown else { return [] }
            isDown = false
            holdConfirmPending = false
            if swallowing {
                swallowing = false
                return []
            }
            if isLatched {
                // Down for a shortcut, not to finish: the run carries on.
                if isCancelled {
                    isCancelled = false
                    return []
                }
                // A tap straight after the latch is the end of a burst of
                // taps meant as "stop", not a finished question: undo.
                let quick = t - pressedAt < tapThreshold
                    && latchedAt.map { pressedAt - $0 < quickUndoWindow } == true
                // Tap or hold, either ends it and sends: the key was
                // pressed on purpose. Never a second latch.
                isLatched = false
                latchedAt = nil
                swallowPressesUntil = t + doubleTapWindow
                return quick ? [.unlatch(.undo), .cancel] : [.unlatch(.tap), .release]
            }
            if isCancelled {
                isCancelled = false
                secondPress = false
                return []
            }
            let held = t - pressedAt
            if secondPress {
                secondPress = false
                guard held < tapThreshold else { return [.release] }
                doubleTapJustHappened = true
                lastDoubleTapAt = t
                return [.doubleTap]
            }
            guard held < tapThreshold else { return [.release] }
            tapPending = true
            return [.armTapWindow]

        case .otherKey:
            if isLatched {
                // Typing while hands-free is fine; a key while the talk key
                // is down makes that press a shortcut, not the finish.
                if isDown { isCancelled = true }
                return []
            }
            guard isDown, !swallowing, !isCancelled else { return [] }
            isCancelled = true
            secondPress = false
            holdConfirmPending = false
            return [.cancel]

        case .esc:
            guard isLatched else { return handle(.otherKey) }
            return dropLatch(.esc)

        case .lock:
            guard isLatched else { return [] }
            return dropLatch(.lock)

        case .tapWindowClosed:
            guard tapPending else { return [] }
            tapPending = false
            return [.tap]

        case .latch:
            guard mayLatch, !isDown, !tapPending, !isLatched else { return [] }
            isLatched = true
            latchedAt = lastDoubleTapAt
            return [.latch]

        case .holdThreshold(let t):
            // A stale timer (from the first tap of a double-tap, say) is
            // refused by the clock as well as by the flag.
            guard holdConfirmPending, isDown, !isCancelled, !swallowing, !isLatched,
                  t - pressedAt >= tapThreshold * 0.9 else { return [] }
            holdConfirmPending = false
            return [.holdConfirmed]
        }
    }

    /// Esc or the lock: the turn is dropped, and a key still down when it
    /// happened has nothing left to finish.
    private mutating func dropLatch(_ reason: UnlatchReason) -> [Action] {
        isLatched = false
        latchedAt = nil
        swallowing = isDown
        isCancelled = false
        return [.unlatch(reason), .cancel]
    }

    /// Forget everything (the tap was switched off, or the turn was taken
    /// down by something other than the key).
    mutating func reset() {
        isDown = false
        pressedAt = 0
        tapPending = false
        secondPress = false
        isCancelled = false
        isLatched = false
        doubleTapJustHappened = false
        swallowPressesUntil = nil
        swallowing = false
        lastDoubleTapAt = nil
        latchedAt = nil
        holdConfirmPending = false
    }

    /// Every action a sequence of events produces, from a fresh machine.
    /// Pure: what the tests ask "is this a press, a cancel or a double-tap?"
    static func actions(for events: [Event], tapThreshold: Double = 0.22,
                        doubleTapWindow: Double = 0.35) -> [Action] {
        var m = TalkChordMachine(tapThreshold: tapThreshold, doubleTapWindow: doubleTapWindow)
        return events.flatMap { m.handle($0) }
    }
}
