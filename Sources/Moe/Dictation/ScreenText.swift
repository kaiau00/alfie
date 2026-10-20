import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The text visible in the window being dictated into, read through
/// Accessibility at the moment the key goes down.
///
/// `CursorContext` answers "what am I in the middle of typing"; this answers
/// "what is in front of me while I say it". The names in a Slack channel
/// list, the identifiers in the file open in the editor, the recipients on
/// the email being replied to — these are the words a speaker is most likely
/// to say next, and the ones a recogniser is least likely to get right,
/// because they are the ones that are not in its language model.
///
/// Only term-shaped words ever leave this file's caller (`ContextTerms`
/// throws away the prose and keeps the names), and nothing here is stored or
/// logged. Read on the same Accessibility grant the paste already needs.
///
/// **Budgeted, not thorough.** This runs on the main thread on the keypress,
/// so it gets a few milliseconds and whatever it has by then is the answer. A
/// window tree can be tens of thousands of nodes deep in an Electron app; a
/// partial read costs a few missing names and a complete one would cost a
/// visibly late chime. Wispr Flow makes the same trade — its context read is
/// skipped outright if it cannot finish quickly.
enum ScreenText {

    /// Wall clock for the whole walk. Chosen against the reveal delay: the
    /// glow and the chime are the user's evidence the key registered, and
    /// nothing may push them late.
    static let budget: TimeInterval = 0.030
    /// Nodes visited before giving up regardless of the clock.
    static let maxNodes = 800
    /// Depth, so a pathological tree cannot spend the whole budget going
    /// down one branch.
    static let maxDepth = 24
    /// Total characters collected from the window.
    static let maxChars = 6_000
    /// Most of any single element's value. A text view holding a whole
    /// document must not be the only thing in the harvest.
    static let maxPerNode = 1_200

    /// Roles whose value is worth reading. Static text is labels, headers
    /// and message bodies; the field roles are what the user types into.
    static let textRoles: Set<String> = [
        "AXStaticText", "AXTextField", "AXTextArea", "AXHeading", "AXLink", "AXCell",
    ]

    /// Never descend into one of these. A password field's contents are off
    /// limits, and so is anything nested inside one. A browser's web area is
    /// deliberately *not* excluded — Gmail and Slack in a tab are exactly
    /// where the names are — which is what the node and time budgets are for.
    static let skipRoles: Set<String> = ["AXSecureTextField"]

    /// Text worth mining, most relevant first: what is in the focused field,
    /// then everything else in the window. Empty when there is nothing to be
    /// had — no Accessibility, no window, or the budget ran out first.
    @MainActor
    static func sources() -> [String] {
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted() else { return [] }
        let system = AXUIElementCreateSystemWide()

        var near = ""
        if let focused = element(of: system, kAXFocusedUIElementAttribute),
           role(of: focused) != "AXSecureTextField",
           let value = string(of: focused, kAXValueAttribute) {
            near = String(value.prefix(maxPerNode))
        }

        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return [near].filter { !$0.isEmpty }
        }
        let app = AXUIElementCreateApplication(pid)
        guard let window = element(of: app, kAXFocusedWindowAttribute)
                ?? element(of: app, kAXMainWindowAttribute) else {
            return [near].filter { !$0.isEmpty }
        }

        var far = string(of: window, kAXTitleAttribute).map { $0 + "\n" } ?? ""
        collect(from: window, into: &far, deadline: Date().addingTimeInterval(budget))
        return [near, far].filter { !$0.isEmpty }
    }

    /// Breadth-first, so the budget buys the top of the window — toolbars,
    /// headers, the visible list — rather than the deepest corner of one
    /// panel. Depth-first here would routinely return a single sidebar.
    @MainActor
    private static func collect(from root: AXUIElement, into out: inout String, deadline: Date) {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = 0

        while !queue.isEmpty, visited < maxNodes, out.count < maxChars, Date() < deadline {
            let (element, depth) = queue.removeFirst()
            visited += 1

            let role = role(of: element)
            if let role, skipRoles.contains(role) { continue }

            if let role, textRoles.contains(role),
               let text = string(of: element, kAXValueAttribute)
                       ?? string(of: element, kAXTitleAttribute),
               !text.isEmpty {
                out += text.prefix(maxPerNode) + "\n"
            }

            guard depth < maxDepth else { continue }
            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }
    }

    @MainActor
    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &ref) == .success,
              let array = ref as? [AnyObject] else { return [] }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID()
                ? unsafeBitCast($0, to: AXUIElement.self) : nil
        }
    }

    @MainActor
    private static func element(of parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    @MainActor
    private static func role(of element: AXUIElement) -> String? {
        string(of: element, kAXRoleAttribute)
    }

    @MainActor
    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        guard let text = ref as? String, !text.isEmpty else { return nil }
        return text
    }
}
