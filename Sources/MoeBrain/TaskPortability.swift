import Foundation

/// Whether an ask may leave the Mac — declared from what the turn has
/// reached for, never guessed from its words. A turn that has used a tool
/// only this Mac has (its files, its screen, its apps) is the Mac's to finish:
/// the cloud would start over without the thing the turn was about.
///
/// The names are Hermes's tool names as `hermes.tool.progress` reports them.
/// Kept as a declared list rather than derived, so a reviewer can read what
/// pins a turn to the Mac; the day the capability tables name each tool's
/// runtime this should read them instead.
public enum TaskPortability {
    public static let macOnlyTools: Set<String> = [
        "computer_use", "terminal", "read_file", "write_file", "patch", "search_files",
        "process", "process_manage", "screenshot", "clipboard",
    ]
    /// Tool-name prefixes of the Mac-only connectors (Apple apps, EventKit).
    public static let macOnlyPrefixes: [String] = [
        "imessage", "notes", "calls", "contacts", "eventkit", "apple_", "mac_", "finder",
    ]

    public static func isMacOnly(tool: String) -> Bool {
        let name = tool.lowercased()
        if macOnlyTools.contains(name) { return true }
        return macOnlyPrefixes.contains { name.hasPrefix($0) }
    }

    /// Tools whose name says they send, pay, book, post or delete — the
    /// classes the send gate asks about. A turn that has reached for one is
    /// never re-issued unasked after a sleep (`TurnKeeper.verdict`): doing it
    /// twice is the one outcome worse than not doing it. Declared, by
    /// substring, because tool names on the wire are the connectors' own
    /// (`gmail_send`, `mcp__composio__SLACK_SEND_MESSAGE`, `imessage_send`).
    public static let consequentialWords: [String] = [
        "send", "reply", "post", "publish", "pay", "purchase", "buy", "checkout", "book",
        "order", "transfer", "delete", "remove", "cancel", "submit", "create_event", "invite",
    ]

    public static func isConsequential(tool: String) -> Bool {
        let name = tool.lowercased()
        return consequentialWords.contains { name.contains($0) }
    }
}
