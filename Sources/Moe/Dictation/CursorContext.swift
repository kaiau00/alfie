import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MoeDictation

/// The text already in the field, immediately before the cursor.
///
/// The polish pass has always known *which app* you are typing into and
/// nothing about *what you are typing into it*. That is the difference
/// between a rewrite that guesses and one that fits: dictating "sounds good
/// let's do thursday" into a half-written reply should continue the sentence
/// you are in, match the capitalisation you have been using, and spell the
/// name that is already three lines up the same way you spelled it there.
///
/// Read through Accessibility, which is a permission Moe already holds —
/// the paste needs it. Same read the system's own text services do.
///
/// **What this deliberately does not do.** It never reads a secure field, it
/// never takes more than `limit` characters, it never looks at anything but
/// the element with keyboard focus (not the window, not the screen), and
/// nothing here — or anywhere downstream — logs the text. It is a prefix of
/// what the user is themselves typing into, handed to the same brain that is
/// already being shown the transcript, and it goes no further.
enum CursorContext {

    /// How much of the preceding text to take. Long enough to carry a
    /// sentence in progress and a name mentioned earlier; short enough that
    /// it can never become "the document" — and short enough not to move the
    /// polish budget, which is the whole reason dictation feels instant.
    static let limit = 320

    /// The text just before the insertion point, or nil when there is none
    /// to be had — no focus, a secure field, an element that does not expose
    /// its value, or a cursor already at the start.
    ///
    /// Returns nil rather than "" throughout: an empty field and a field we
    /// could not read must not look the same to the caller, because the
    /// first is worth telling the model about and the second is not.
    @MainActor
    static func textBeforeCursor(limit: Int = CursorContext.limit) -> String? {
        // A password field is off limits, and while secure input is on the
        // paste is refused anyway (see TextInserter) — so there is nothing
        // this could usefully inform.
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted() else { return nil }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        // Belt and braces: the system-wide check above is global state, this
        // is the element itself saying so.
        // "AXSecureTextField" spelled out: the constant lives in HIServices
        // and is not surfaced to Swift, and NSAccessibility.Role has no case
        // for it either.
        var secureRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &secureRef) == .success,
           (secureRef as? String) == "AXSecureTextField" { return nil }

        guard let value = string(of: element, kAXValueAttribute) else { return nil }
        // The insertion point. Without it there is no "before", and taking
        // the tail of the field would be a guess that is wrong every time
        // the user is editing in the middle of something.
        guard let caret = insertionPoint(of: element) else { return nil }

        let utf16 = value.utf16
        guard caret > 0, caret <= utf16.count else { return caret == 0 ? "" : nil }
        let start = utf16.index(utf16.startIndex, offsetBy: max(0, caret - limit))
        let end = utf16.index(utf16.startIndex, offsetBy: caret)
        return String(utf16[start..<end])
    }

    /// The caret's offset in UTF-16 units, from `kAXSelectedTextRange`. When
    /// there is a selection this is its start — dictation replaces a
    /// selection, so what precedes it is the context that survives.
    @MainActor
    private static func insertionPoint(of element: AXUIElement) -> Int? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range)
        else { return nil }
        return range.location >= 0 ? range.location : nil
    }

    @MainActor
    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// The prefix worth sending, or nil. `CursorPrefix` (MoeDictation) so the
    /// trimming rules can be tested without a focused window.
    static func tidy(_ text: String?) -> String? { CursorPrefix.tidy(text) }
}
