import Foundation

/// A reply's markdown, as the attributed text both the chat window and the
/// island draw it from.
///
/// One parse for both surfaces. The island used to parse only a reply that
/// contained a link, and show every other one raw — so "**Tomorrow is Yom
/// Kippur**" reached the notch with its asterisks on (reported 2026-09-20:
/// "why does it show * often"), while the same reply in the window was
/// bold. The model writes markdown; every place that shows its words has to
/// read it.
public enum ReplyMarkdown {

    /// Inline only, and whitespace preserved: full markdown parsing collapses
    /// the line breaks that make a list a list.
    ///
    /// `BareLinks.autolink` runs first so a bare `https://example.com` — far
    /// and away the commonest shape a model writes — arrives at the parser as
    /// markdown it already knows how to make clickable.
    public static func inline(_ text: String) -> AttributedString {
        let source = BareLinks.autolink(text)
        return (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}
