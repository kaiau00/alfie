import AppKit
import CoreGraphics
import Foundation
import MoeDesign
import SwiftUI

// The dialog in front of every send. `moe-home/tools/confirm.sh` runs this,
// hands it the message on stdin, and reads the answer out of the exit status:
//
//   0  the human clicked Send
//   1  the human cancelled
//   2  the dialog could not be shown at all — no screen, nothing on stdin, a
//      request it could not parse, a run loop that ended without an answer.
//      confirm.sh falls back to its AppleScript dialog on this, so "I could
//      not ask" never becomes "yes".
//   3  --describe: what was parsed, printed; nothing shown, nothing approved
//   4  the human clicked "Always allow" on an act (kind=act): approved, and
//      the hook records the tool as allowed. A send never exits 4.
//   7  withdrawn: the process that asked is gone, or the deadline passed
//      with nobody answering. A sentence saying nothing was sent is left in
//      the person's inbox. See ConfirmLifecycle.
//   5  the human rewrote the message and clicked Send: approved AS EDITED.
//      What changed is on stdout, as the same NUL-separated `key=value`
//      records the request came in on — `body=…`, `subject=…`, only the
//      fields that changed — and the caller sends those words, not the ones
//      it asked about. A caller that predates this reads 5 as "not 0", so
//      the worst an old caller can do with a new dialog is not send.
//
// 2 and 3 are deliberately not 0, and the bottom of this file exits 2 rather
// than falling off the end, because falling off the end of `main` is exit 0
// and exit 0 is a send. Every path out of this file that is not a person
// clicking Send has to be a path that does not send.

let CONFIRM_APPROVED: Int32 = 0
let CONFIRM_CANCELLED: Int32 = 1
let CONFIRM_UNAVAILABLE: Int32 = 2
let CONFIRM_DESCRIBED: Int32 = 3
/// "Always allow" on an act: run it, and the hook records the tool as allowed.
let CONFIRM_ALWAYS: Int32 = 4
/// Send, with the words the person rewrote — which are on stdout.
let CONFIRM_EDITED: Int32 = 5
/// "Allow everything this session" on a session dialog: send this, and the
/// hook records that every browser class and every screen send in this
/// conversation runs unasked until it has been quiet for an hour. Never
/// offered on a plain send or an act, and never remembered past that hour.
let CONFIRM_SESSION: Int32 = 6
/// Withdrawn: whoever asked went away, or nobody answered before the
/// deadline (`ConfirmLifecycle`). Not a send, not a Cancel, and not "could
/// not ask" — confirm.sh must not answer a 7 by drawing its other dialog.
let CONFIRM_WITHDRAWN: Int32 = ConfirmLifecycle.exitWithdrawn

let arguments = Array(CommandLine.arguments.dropFirst())
let describing = arguments.contains("--describe")
let positional = arguments.filter { !$0.hasPrefix("--") }

// The secret window (SecretMain.swift): a password or a sign-in code, typed
// by the person, answered as JSON on stdout. Decided first, before this
// file's signal handlers or its NUL-separated reader, neither of which
// speaks that contract. It never returns.
if SecretRequest.isSecretInvocation(argv: CommandLine.arguments) {
    runSecretPrompt(arguments: arguments)
}

// Signals first, before stdin is read or anything is drawn (ConfirmLifecycle):
// a hang-up that arrives this early is queued here and answered — with the
// note — once the run loop starts, instead of taking the default action and
// leaving without a word. SIGHUP is "the requester hung up" (the connectors
// plugin, when the turn that asked has ended); TERM/INT is "closed".
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGHUP, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { withdraw(sig == SIGHUP ? .requesterGone : .terminated) }
    source.resume()
    signalSources.append(source)
}

/// stdin unless someone is driving this by hand from a terminal, which is the
/// only reason the argv form exists — a real message must never travel on
/// argv, where `ps` shows it to every process on the Mac.
let request: ConfirmRequest = {
    if isatty(0) == 1 && !positional.isEmpty {
        return ConfirmRequest.parse(argv: positional)
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if data.isEmpty && !positional.isEmpty {
        return ConfirmRequest.parse(argv: positional)
    }
    return ConfirmRequest.parse(data)
}()

/// Printable, and unambiguous: `\n` for a newline, `⟨U+00XX⟩` for anything
/// else that does not draw.
func escaped(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        default:
            if ConfirmRequest.steering.contains(scalar) {
                out += String(format: "⟨U+%04X⟩", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

if describing {
    let service = Service.identify(channel: request.channel, tool: request.tool, hint: request.service)
    let parts = request.fields
    print("service\t\(escaped(service.label))")
    print("icon\t\(service.icon)")
    print("to\t\(escaped(request.displayedTo))")
    print("tool\t\(request.tool)")
    print("action\t\(escaped(request.action))")
    print("kind\t\(request.kind)")
    print("editable\t\(request.editable)")
    print("detail\t\(escaped(request.detail))")
    print("headline\t\(escaped(ConfirmRequest.legibleLine(request.headline)))")
    print("cancel\t\(request.cancelLabel)")
    print("subjecteditable\t\(request.subjectEditable)")
    print("steered\t\(request.steered)")
    print("headercount\t\(parts.headers.count)")
    if let confusable = request.confusableRecipient { print("confusable\t\(escaped(confusable))") }
    if let provenance = request.provenance {
        print("provenance\t\(provenance.isWarning ? "warn" : "plain")\t\(escaped(provenance.line))")
        for warning in provenance.warnings { print("provenancewarning\t\(escaped(warning))") }
    }
    for header in parts.headers { print("header\t\(header.0)\t\(escaped(header.1))") }
    // Every non-printable named, not just newlines: a body containing CR, a
    // paragraph separator, or the literal two characters `\n` printed
    // identically to one containing a real newline, which makes this a lossy
    // thing to write a test against.
    print("requester\t\(ConfirmLifecycle.pids(request.requester).map(String.init).joined(separator: " "))")
    print("deadline\t\(ConfirmLifecycle.deadline(request.deadline).map { String(Int($0.timeIntervalSince1970)) } ?? "")")
    print("origin\t\(escaped(ConfirmRequest.legibleLine(request.origin)))")
    print("body\t\(escaped(request.displayedBody))")
    exit(CONFIRM_DESCRIBED)
}

// `--snapshot <file.png>`: the card drawn to a picture (light and dark),
// never on screen and never answerable — the same contract as the password
// window's (SecretMain.swift). Exits 3, like --describe: nothing approved.
if let at = arguments.firstIndex(of: "--snapshot"), at + 1 < arguments.count {
    let path = arguments[at + 1]
    MainActor.assumeIsolated { snapshotConfirmSheet(request, to: path) }
    exit(CONFIRM_DESCRIBED)
}

@MainActor
func snapshotConfirmSheet(_ request: ConfirmRequest, to path: String) {
    _ = NSApplication.shared
    for (suffix, name) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
        let sheet = ConfirmSheet(request: request, onSend: { _ in }, onCancel: {},
                                 onAlways: {}, onAllowSession: {}).padding(24)
        let hosting = NSHostingView(rootView: sheet)
        hosting.appearance = NSAppearance(named: name)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: name)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let out = (path as NSString).deletingPathExtension + suffix + ".png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        print(out)
    }
}

// MARK: - The card's own life (ConfirmLifecycle)
//
// Started before anything is drawn, and the same in every mode: whoever asked
// is watched, the card's parent is watched, the clock is watched, and a
// SIGTERM/SIGHUP/SIGINT is treated as the requester calling it off. Every one
// of them ends in `withdraw`, which leaves a sentence in the inbox and exits
// 7 — never 0.
let requesters = ConfirmLifecycle.pids(request.requester)
let cardDeadline = ConfirmLifecycle.effectiveDeadline(
    ConfirmLifecycle.deadline(request.deadline),
    longest: ConfirmLifecycle.ceiling(environment: ProcessInfo.processInfo.environment))
var lifecycleSources: [DispatchSourceProtocol] = []

/// Set once the card is on screen. A card the person saw go does not also
/// leave them a note about it (`ConfirmLifecycle.leavesNote`).
var cardShown = false

func withdraw(_ reason: ConfirmLifecycle.Reason) -> Never {
    FileHandle.standardError.write(Data("moe-confirm: withdrawn — \(reason.rawValue); nothing was sent\n".utf8))
    let environment = ProcessInfo.processInfo.environment
    let home = ConfirmLifecycle.home(request.home, environment: environment)
    let presence = try? Data(contentsOf: home.appendingPathComponent("presence.json"))
    let atMac = ConfirmLifecycle.ownerAtMac(presence: presence)
    let noted = ConfirmLifecycle.leavesNote(shown: cardShown, ownerAtMac: atMac)
    if noted {
        let note = ConfirmLifecycle.withdrawnNote(channel: request.channel, to: request.displayedTo,
                                                  kind: request.kind, reason: reason)
        let inbox = ConfirmLifecycle.inbox(home: request.home, environment: environment)
        do {
            try ConfirmLifecycle.writeNote(note, inbox: inbox)
        } catch {
            FileHandle.standardError.write(Data("moe-confirm: could not leave a note in \(inbox.path): \(error)\n".utf8))
        }
    } else {
        FileHandle.standardError.write(Data(
            "moe-confirm: no inbox note (\(cardShown ? "the card was on screen" : "the person is at the Mac"))\n".utf8))
    }
    DistributedNotificationCenter.default().postNotificationName(
        ConfirmSignal.withdrawn, object: nil,
        userInfo: [ConfirmSignal.pidKey: String(ProcessInfo.processInfo.processIdentifier),
                   ConfirmSignal.notedKey: noted ? "yes" : "no"],
        deliverImmediately: true)
    exit(CONFIRM_WITHDRAWN)
}

func startLifecycle() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(500))
    timer.setEventHandler {
        if let reason = ConfirmLifecycle.check(requesters: requesters, parent: getppid(),
                                               deadline: cardDeadline) {
            withdraw(reason)
        }
    }
    timer.resume()
    lifecycleSources.append(timer)
    // The signal sources are at the top of this file, installed before
    // anything else can happen.
}

// `--withdraw-test`: the lifecycle with no window, so the guarantee above can
// be tested on a machine with a person at it without putting a card on their
// screen. There are no buttons in this mode, so there is nothing that can
// exit 0: it leaves by withdrawing (7) or not at all.
if arguments.contains("--withdraw-test") {
    startLifecycle()
    dispatchMain()
}

// Nothing to show, or nothing to show it on. Both are "could not ask".
if request.malformed {
    FileHandle.standardError.write(Data("moe-confirm: the request did not parse\n".utf8))
    exit(CONFIRM_UNAVAILABLE)
}
if request.body.isEmpty && request.to.isEmpty && request.channel.isEmpty {
    FileHandle.standardError.write(Data("moe-confirm: nothing to confirm\n".utf8))
    exit(CONFIRM_UNAVAILABLE)
}
if CGMainDisplayID() == 0 {
    FileHandle.standardError.write(Data("moe-confirm: no display to ask on\n".utf8))
    exit(CONFIRM_UNAVAILABLE)
}

/// An answer has to be something a person *did*, so for the first half second
/// the dialog will not take one.
///
/// This is not theoretical, and it is not about the keyboard. A window that
/// appears in the middle of the screen appears *under the pointer*, and a
/// click already on its way down — at the terminal, at a browser tab, at
/// whatever was there a moment ago — lands on whichever button is now in that
/// spot. That was reproducible here: a stack trace from the phantom answer
/// came in through `-[NSWindow sendEvent:]` and the gesture recognisers, an
/// ordinary mouse click on a button nobody had looked at yet.
///
/// Only the answers that APPROVE are held — Send, Always allow, Allow this
/// session. Cancel used to be held too, on the reasoning that a click that
/// arrives before a human could have read a word is not a decision either
/// way. It cost more than it saved: a phantom Cancel sends nothing and the
/// model can simply ask again, while a held Cancel is a button that visibly
/// does nothing when a person presses it — which is what the owner met on
/// 2026-09-25, on a card they could not get rid of.
enum Approval {
    /// Set when the window goes on screen, not at launch: reading the message
    /// off stdin happens first, and on a slow pipe that is time the guard
    /// would otherwise spend counting down behind a window nobody can see.
    ///
    /// Monotonic, not wall-clock. `Date()` moves when the clock is corrected,
    /// and a backward NTP step inside the window would leave both buttons
    /// dead until the clock caught up — a dialog nobody can answer, in front
    /// of a send. `systemUptime` only ever goes forward.
    private static var armedAt = Double.infinity

    /// Long enough to outlast a click that was already in flight; short
    /// enough that nobody who meant it notices.
    static func arm(after delay: TimeInterval = 0.5) {
        armedAt = ProcessInfo.processInfo.systemUptime + delay
    }

    /// Judged on when the click was MADE, not when SwiftUI ran the action.
    /// A click generated before the window existed and delivered late is
    /// exactly the accident this guards, and the main thread can stall for
    /// seconds on a long message. `NSEvent.timestamp` shares its base with
    /// `systemUptime`.
    ///
    /// No event at all is also not an answer: an accessibility press or a
    /// programmatic `performClick` arrives with `currentEvent` nil.
    static var ready: Bool {
        guard let event = NSApp.currentEvent else { return false }
        return event.timestamp >= armedAt
    }
}

/// A borderless window is not key-eligible unless it says so, and a dialog
/// that cannot take the keyboard is a dialog where Escape does nothing.
/// Borderless is what buys the 22pt corner radius and the absence of a
/// titlebar; this is the one line it costs.
final class ConfirmWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A quit is not a Send.
///
/// `NSApplication.terminate(_:)` exits the process itself, with status 0 —
/// and 0 is this program's word for "the human clicked Send". Anything that
/// can send this app a quit AppleEvent could therefore send the message:
/// logging out, restarting, Activity Monitor's Quit, `osascript -e 'tell
/// application … to quit'`, or any local process that can post one. It never
/// reaches the `exit(CONFIRM_UNAVAILABLE)` at the bottom of this file,
/// because `terminate:` does not return through `run()`.
///
/// So the last word goes here: whatever asked us to quit, nobody clicked
/// anything, and the answer is "could not ask".
final class ConfirmDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileHandle.standardError.write(Data("moe-confirm: asked to quit before anyone answered\n".utf8))
        exit(CONFIRM_UNAVAILABLE)
    }
}

let application = NSApplication.shared
let delegate = ConfirmDelegate()
application.delegate = delegate
// No Dock icon and no menu bar: this is a prompt, not an app. It still takes
// the keyboard — `activate` below is what an accessory needs for that.
application.setActivationPolicy(.accessory)

// An Edit menu, never shown (an accessory has no menu bar), so that ⌘X ⌘C ⌘V
// ⌘A ⌘Z reach the subject and message fields. Without a main menu there is
// nothing for the key equivalent to match, and paste did nothing (the owner,
// 2026-09-25, pasting a subject into a Gmail send card). No Quit and no other
// item: nothing here can answer the card.
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
redo.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
editItem.submenu = editMenu
let mainMenu = NSMenu()
mainMenu.addItem(editItem)
application.mainMenu = mainMenu

/// The rewritten fields, on stdout, in the request's own record format —
/// and then exit 5. Written whole before the exit, because a caller reading
/// half a record and an exit status of 5 would be a caller sending half a
/// message. NUL cannot appear in a value: `ConfirmRequest.parse` refused
/// any request carrying one, and the editor cannot type one.
func sendEdited(_ edits: ConfirmEdits) {
    var out = Data()
    if let body = edits.body { out.append(Data("body=\(body)\u{0}".utf8)) }
    if let subject = edits.subject { out.append(Data("subject=\(subject)\u{0}".utf8)) }
    FileHandle.standardOutput.write(out)
    exit(CONFIRM_EDITED)
}

let sheet = ConfirmSheet(
    request: request,
    onSend: { edits in
        guard Approval.ready else { return }
        if let edits, request.editable { sendEdited(edits) }
        exit(CONFIRM_APPROVED)
    },
    // Cancel is never held. The half-second guard exists so a click already in
    // flight cannot SEND; a phantom Cancel sends nothing, and holding Cancel
    // is what made the owner's clicks on it do nothing (2026-09-25).
    onCancel: { exit(CONFIRM_CANCELLED) },
    onAlways: { if Approval.ready && request.kind == "act" { exit(CONFIRM_ALWAYS) } },
    onAllowSession: { if Approval.ready && request.kind == "session" { exit(CONFIRM_SESSION) } },
    onResize: { DispatchQueue.main.async { resizeCard() } })

/// "Show details" opened or closed: the card takes its new height, keeping
/// its top edge where the person was reading it, and never taller than the
/// screen (the clamp below, for the same reason). Set once the window exists.
var resizeCard: () -> Void = {}

/// Takes the first click. Without this the click that brings an inactive
/// card forward is spent on activating it, and a person pressing Cancel on a
/// card behind their chat pressed it twice and saw nothing happen the first
/// time. Send stays safe: becoming key re-arms its guard (below), so a first
/// click that lands on Send is still not an answer.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

startLifecycle()

let hosting = FirstClickHostingView(rootView: sheet)
let window = ConfirmWindow(contentRect: .zero,
                           styleMask: [.borderless, .fullSizeContentView],
                           backing: .buffered,
                           defer: false)
window.contentView = hosting
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = true
window.isMovableByWindowBackground = true
// Above ordinary windows when it ARRIVES, so it is not lost behind whatever
// the person was doing — but only until they look away from it. The first
// time it stops being the key window it drops to the normal level, where
// the chat and everything else can come in front of it again (the owner,
// 2026-09-25: floating over every window on every desktop, it "blocked the
// chat"). It stays on every Space, so it is always one click away.
window.level = .floating
NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                       object: window, queue: .main) { _ in
    window.level = .normal
}
// On every Space, full-screen apps included. A confirmation waiting on a
// desktop you have left is a send that looks hung. `.moveToActiveSpace` only
// moved it when it was activated, so switching desktops left it behind on the
// one it arrived on (the owner, 2026-09-25: "it stays in whichever window it
// first arrived and if I switch windows I don't see it").
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
// Sized from the hosting view before it is shown: a window created at .zero
// and centred before SwiftUI has measured it lands in the corner, and the
// first version of this put the dialog half off the top of the screen.
// `fittingSize` asks the hosting view how big it wants to be without forcing
// a layout pass on the window itself.
// Clamped to the screen, always. Height was taken from the content, and a
// body of 400 newlines — 413 characters, so under every character cap —
// produced a 7,117pt window: the recipient visible at the top, the message,
// the tool id and BOTH BUTTONS six thousand points below the bottom of the
// display. A dialog whose Cancel cannot be reached is not a dialog.
let fitting = hosting.fittingSize
let ceiling = (NSScreen.main?.visibleFrame.height ?? 800) - 40
window.setContentSize(CGSize(width: fitting.width, height: min(fitting.height, ceiling)))
window.center()
// Out of the way of Memoe's own windows when there is room (ConfirmPlacement).
// Window bounds and owner names need no Screen Recording permission.
if let screen = NSScreen.main {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] ?? []
    let avoid: [CGRect] = listed.compactMap { info in
        guard let owner = info[kCGWindowOwnerName as String] as? String,
              ConfirmPlacement.appNames.contains(owner),
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        let cocoa = ConfirmPlacement.cocoaRect(fromWindowServer: rect, primaryHeight: primaryHeight)
        // A full-width strip (the island's own panel) is not a window to
        // step around; nothing would ever fit beside it.
        guard cocoa.width < screen.frame.width * 0.9, cocoa.height > 40 else { return nil }
        return cocoa
    }
    window.setFrameOrigin(ConfirmPlacement.origin(card: window.frame.size,
                                                  visible: screen.visibleFrame, avoid: avoid))
}
// Never exactly on top of another confirmation. Two of these landed on
// identical pixels: a person answered the one they could see, it vanished,
// and an indistinguishable second dialog was revealed under the pointer —
// with its guard long expired, so the next click answered a message nobody
// had read. Offset by however many are already up.
// Counting the other confirmations at launch is not enough: two started in
// the same instant each read the list before the other had registered, and
// both landed on identical pixels. The process id is the one number that is
// unique per dialog, so it decides the offset — same effect, no race.
// Always, not "if another one is up". Two dialogs started in the same instant
// each counted the other before it had registered, found none, and both
// skipped the offset onto identical pixels — the race the offset was written
// to remove. An offset on a lone dialog costs nothing, so there is nothing to
// gate on: the process id decides the slot, and two processes cannot share
// one.
let slot = CGFloat(Int(ProcessInfo.processInfo.processIdentifier) % 7)
window.setFrameOrigin(NSPoint(x: window.frame.origin.x + slot * 26,
                              y: window.frame.origin.y - slot * 26))

resizeCard = {
    let wanted = hosting.fittingSize
    let height = min(wanted.height, (window.screen ?? NSScreen.main)
        .map { $0.visibleFrame.height - 40 } ?? 760)
    var frame = window.frame
    frame.origin.y += frame.height - height
    frame.size = CGSize(width: wanted.width, height: height)
    if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, frame.minY < visible.minY {
        frame.origin.y = visible.minY
    }
    window.setFrame(frame, display: true, animate: false)
}

application.activate(ignoringOtherApps: true)
window.makeKeyAndOrderFront(nil)
cardShown = true
Approval.arm()

// Tell Moe the sheet is up and waiting on a person. Without this Moe cannot
// know: Hermes reported the send step before its hook put this window up, and
// the hook blocks until this process exits, so all Moe could say was "still
// getting that ready to send" to someone who was meant to press a button.
// Nothing about the message goes in here — any process can observe a
// distributed notification. See MoeDesign/ConfirmSignal.swift.
//
// "Answered" is posted from atexit, because every way out of this file is an
// `exit(…)` — Send, Cancel, Always allow, an edit, a quit, the run loop
// ending — and one handler is the only way to be sure none of them is missed.
// It only fires after "waiting" did, so a request that never reached a screen
// says nothing at all. A SIGKILL posts neither; the app also clears its wait
// when the step or the turn ends.
var announcedWaiting = false
func postConfirmSignal(_ name: Notification.Name, _ info: [String: String]) {
    DistributedNotificationCenter.default().postNotificationName(
        name, object: nil, userInfo: info, deliverImmediately: true)
}
postConfirmSignal(ConfirmSignal.waiting, [
    ConfirmSignal.kindKey: request.kind,
    ConfirmSignal.editableKey: request.editable ? "yes" : "no",
    ConfirmSignal.pidKey: String(ProcessInfo.processInfo.processIdentifier),
])
announcedWaiting = true
atexit {
    guard announcedWaiting else { return }
    postConfirmSignal(ConfirmSignal.answered, [
        ConfirmSignal.pidKey: String(ProcessInfo.processInfo.processIdentifier),
    ])
}
// And again every time it becomes the key window. A dialog revealed from
// underneath another one is newly in front of a person who has not read it
// yet, whatever its own clock says.
NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                       object: window, queue: .main) { _ in
    Approval.arm()
}

// `--quit-test` exists so the guarantee above can be tested rather than
// argued. It asks the app to terminate the way a logout, Activity Monitor or
// a quit AppleEvent would, and the only honest outcome is 2 — never 0. It
// cannot approve anything: the delegate is the only thing that answers it.
if arguments.contains("--quit-test") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        application.terminate(nil)
    }
}

application.run()

// `run()` returning means the loop ended without a button being clicked — the
// app was terminated, the window went away, something failed.
FileHandle.standardError.write(Data("moe-confirm: dismissed without an answer\n".utf8))
exit(CONFIRM_UNAVAILABLE)
