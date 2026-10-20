import Foundation

/// **A file whose contents are baked into the system prompt, and the one
/// question worth asking about it: has it changed since the prompt was
/// built?**
///
/// Moe's system prompt is assembled once, when the brain starts, and Hermes
/// bakes it into its Claude Code child at spawn. Everything in it is
/// therefore frozen for the life of that child. That is the right trade for
/// almost all of it — `BrainPrompt.briefBlock()` records the measurement:
/// 1,387 logged turns, 151 of them (11%) with the child respawning
/// underneath, p50 8.1 s to first token against 5.6 s warm — which is why the
/// brief was moved off the prompt and onto the turn.
///
/// `context/_connections.md` is the exception, and on 2026-09-07 it cost the
/// owner the thing the file exists to prevent. He connected two Gmail
/// accounts at 21:34, asked "are you connected to my Gmail?" at 21:36, and
/// was told *"No — no mailbox is added yet, so I can't see your Gmail at
/// all. Want me to walk you through connecting it?"*. The brain had started
/// at 21:31:12 (`brain ready: 1 tool(s), 0 connection(s)`) and its prompt was
/// built from a `_connections.md` written before the Composio project existed
/// — the project was minted at 21:33:43. Nothing rebuilt the prompt, so the
/// answer was the truth as of two minutes before the connection.
///
/// ## Why content and not a timestamp
///
/// `sync.sh` rewrites `_connections.md` on its ten-minute tick whether or not
/// anything changed. An mtime- or stat-based check would therefore fire six
/// times an hour, all day, and buy a child respawn every single time — the
/// exact bill the brief was moved to stop paying, reintroduced through a
/// different file. The rule the measurement gives is *size is free, change is
/// not*, so what counts as a change here is the bytes differing, and a
/// rewrite of identical bytes is not one.
///
/// Pure enough to test: it owns a URL and reads it, so a test writes real
/// files and watches real answers, rather than agreeing with a decision table
/// it also wrote.
public struct PromptSource {

    /// The file the prompt is built from.
    public let url: URL

    /// What it said when the prompt was last built. `nil` until the first
    /// `take()`, which is the honest answer to "is the prompt stale?" before
    /// there is a prompt: no.
    private var built: String?

    public init(url: URL) { self.url = url }

    /// The file's contents, or `""` when it is missing or unreadable.
    ///
    /// Absent reads as empty rather than throwing because that is exactly
    /// what `BrainPrompt` does with it — it skips an empty block — so the
    /// two agree about what "no connections file" means, and a person who
    /// disconnects their last service (the file goes empty) is a change like
    /// any other rather than a crash or a silence.
    public static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Read it, and record that as what the prompt was built from.
    public mutating func take() -> String {
        let text = Self.read(url)
        built = text
        return text
    }

    /// Does the prompt need rebuilding?
    ///
    /// False before the first `take()`, false while the bytes are unchanged
    /// however often the file is rewritten, and true from the moment the
    /// bytes differ until the next `take()`.
    public func isStale() -> Bool {
        guard let built else { return false }
        return Self.read(url) != built
    }

    /// What changed since the prompt was built, line by line: `-` for a line
    /// that went, `+` for one that came. The rebuild fired 2–11 times a day
    /// (53 in 09-16 → 10-06) with no connect action anywhere near it, and
    /// nothing recorded what had changed, so whatever flaps could not be
    /// found. Order-insensitive; capped so a rewrite cannot flood the log.
    public func changedLines(limit: Int = 6) -> [String] {
        guard let built else { return [] }
        let before = Self.lines(built), after = Self.lines(Self.read(url))
        let went = before.filter { !after.contains($0) }.map { "- " + $0 }
        let came = after.filter { !before.contains($0) }.map { "+ " + $0 }
        return Array((went + came).prefix(limit))
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
