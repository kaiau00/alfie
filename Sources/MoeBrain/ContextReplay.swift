import Foundation

/// Which of the conversation's turns are handed back to a brain that has been
/// restarted.
///
/// Restarting the model's process is the only way to interrupt it, and a new
/// process remembers nothing — so the recent conversation is replayed into it
/// and it carries on. The selection is the whole of that mechanism, and it is
/// here rather than inline because getting it wrong is silent: the brain
/// answers something, just not the thing that was asked.
///
/// It was wrong. `turns.suffix(8).filter { … }` took the last eight turns and
/// *then* dropped the ones with nothing in them, so every dropped turn had
/// still spent a slot. An interruption leaves an empty turn behind and there
/// were 43 of those in two days, which is how this happened on 2026-09-04:
/// the owner asked for five things in one breath, corrected one clause of it
/// sixteen seconds later, and the restarted process was handed
///
///     They said: Yeah
///     You replied: …
///
/// Two hundred and twenty-eight characters. The five-part request was in the
/// transcript the whole time; six of the last eight slots were empties and it
/// never reached the window. Nothing got done, and the cause was the order of
/// two operations rather than anything about interruptions.
public enum ContextReplay {

    /// One side of an exchange, as much of it as this needs to know.
    public struct Line: Equatable, Sendable {
        public enum Who: Sendable, Equatable { case them, us }
        public var who: Who
        public var text: String
        public init(who: Who, text: String) {
            self.who = who
            self.text = text
        }
    }

    /// How many exchanges a restarted brain is given. Eight is what was
    /// there; the fix is that eight now means eight real ones.
    public static let window = 8

    /// A turn worth replaying: one that says something.
    ///
    /// "…" is not empty and is not content either — `abandonSpokenReply`
    /// writes it over a reply the person heard none of, so it passes an
    /// is-empty test while carrying nothing a model could act on. A turn that
    /// is only punctuation or whitespace goes the same way.
    public static func worthReplaying(_ line: Line) -> Bool {
        let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return t.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// The last `window` turns that say something, oldest first.
    public static func recent(_ lines: [Line], window: Int = window) -> [Line] {
        Array(lines.filter(worthReplaying).suffix(window))
    }

    /// The replayed conversation, in the shape the brain is given it.
    public static func script(_ lines: [Line]) -> String {
        recent(lines)
            .map { ($0.who == .them ? "They said: " : "You replied: ") + $0.text }
            .joined(separator: "\n")
    }
}
