import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MoeScreen

/// Puts dictated text at the cursor of whatever app is in front.
///
/// Paste, not synthesised keystrokes: a ⌘V lands a whole sentence — unicode,
/// emoji, newlines — in one event and in every app, whereas typing it key by
/// key is slow, mangles anything the current keyboard layout can't produce,
/// and races the app's own autocomplete. The cost is the clipboard, so
/// whatever was on it is put back once the paste has been taken.
enum TextInserter {

    enum Outcome {
        case pasted
        /// Can't send the keystroke; text left on the clipboard.
        case noAccessibility
        /// Nothing has keyboard focus, or a password field does; text left
        /// on the clipboard for the user to place themselves.
        case noTarget
    }

    /// Restore delay. Apps read the pasteboard synchronously while handling
    /// the ⌘V key-down, so this only has to outlast event delivery — but an
    /// Electron app with a busy main thread can take well over 150 ms to get
    /// to the event. Nobody is watching the clipboard in the meantime, so
    /// erring long costs nothing; restoring early costs the whole paste.
    private static let restoreDelay: TimeInterval = 0.35

    /// Set alongside the text so clipboard managers know to skip this entry
    /// (a de-facto standard: http://nspasteboard.org).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Paste `text` into the focused app and restore the clipboard afterwards.
    /// Without Accessibility the paste keystroke can't be sent, so the text is
    /// left on the clipboard for the user to paste themselves.
    @MainActor
    static func insert(_ text: String) -> Outcome {
        let pb = NSPasteboard.general

        // A paste with nowhere to land loses the text, and the clipboard
        // restore would then wipe the one copy that was left. Keep it on the
        // clipboard instead — as an ordinary entry, so a clipboard manager
        // keeps it too — and say so.
        if let why = pasteTargetProblem() {
            Log.write("dictation: not pasting (\(why)) — text left on clipboard")
            pb.clearContents()
            pb.setString(text, forType: .string)
            return .noTarget
        }

        let saved = snapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: transientType)

        // Never paste under a physically held ⌘/⌥/⌃/⇧: the app would see
        // the keystroke with the real modifier folded in (Terminal reads a
        // ⌘-held paste differently). Short phrases transcribe faster than a
        // thumb lifts, so this is not theoretical.
        waitForModifiersUp()
        guard AXIsProcessTrusted(), sendPaste() else {
            Log.write("dictation: no Accessibility — text left on clipboard")
            return .noAccessibility
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        Log.write("dictation: pasted into \(front)")

        // If anything else writes the clipboard before the restore fires —
        // the user copies, another dictation lands — that write wins; putting
        // the old contents back over it would lose what they just copied.
        let ours = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            guard pb.changeCount == ours else { return }
            restore(saved, to: pb)
        }
        return .pasted
    }

    /// Why a ⌘V would go nowhere, or nil when it is worth sending.
    ///
    /// Secure input (a password field) is never pasted into. Otherwise only
    /// the *absence* of a focused element counts against it: a web view or a
    /// custom widget reports vague roles and is still very likely a text box,
    /// so anything with focus gets the paste.
    private static func pasteTargetProblem() -> String? {
        if IsSecureEventInputEnabled() { return "secure input" }
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                kAXFocusedUIElementAttribute as CFString,
                                                &focused)
        guard err == .success, focused != nil else { return "no focused element (\(err.rawValue))" }
        return nil
    }

    /// Everything currently on the pasteboard, every type of every item, so a
    /// copied file or a styled paragraph comes back exactly as it was.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    any = true
                }
            }
            return any ? copy : nil
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        if !pb.writeObjects(items) {
            Log.write("dictation: clipboard restore failed")
        }
    }

    /// Spin (briefly) until no modifier key is physically down; give up
    /// after 400 ms rather than never pasting.
    private static func waitForModifiersUp() {
        let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(0.4)
        while CGEventSource.flagsState(.combinedSessionState).intersection(mods).rawValue != 0,
              Date() < deadline {
            usleep(10_000)
        }
    }

    /// ⌘V as the hardware would send it, posted at the session tap so it
    /// reaches the front app through the normal path — the same recipe
    /// OpenWhispr and friends ship (virtual key 0x09 + ⌘, nothing else).
    ///
    /// No unicode string is stamped on the event on purpose: AppKit matches
    /// key equivalents on the virtual key and modifiers, and a synthesised
    /// event that also carries characters can be taken for typed text, so the
    /// paste never fires. Non-QWERTY layouts are a known gap for now.
    private static func sendPaste() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        usleep(8_000)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
