import SwiftUI

/// The box you type into, in Chat and on the island: it grows with what you
/// write up to `maxLines`, then scrolls — with the trackpad, like any text.
///
/// Both used to be `TextField`s. A vertical one grows to its line limit and
/// then will not scroll with a trackpad or mouse at all, so a pasted email
/// could only be read by walking the caret down it with the arrow keys (the
/// owner, 2026-09-25); the island's was a single line, worse still.
/// `TextEditor` is an `NSTextView` in a scroll view and scrolls the way text
/// does everywhere else on the Mac.
///
/// Return sends; Shift-Return (or Option-Return) starts a new line, as in
/// Messages and every chat app.
struct ComposerEditor: View {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = 13
    var lineHeight: CGFloat = 17
    var maxLines = 6
    var ink: Color = .primary
    var placeholderInk: Color = .secondary
    var focus: FocusState<Bool>.Binding?
    let onSubmit: () -> Void

    /// NSTextView's own inset from the left edge of its text container.
    private let lead: CGFloat = 5

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the box: the text itself, invisible, one line at least.
            Text(text.isEmpty ? " " : text + " ")
                .font(.system(size: size))
                .lineSpacing(lineHeight - size - 3)
                .padding(.leading, lead)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .accessibilityHidden(true)
            editor
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: size))
                    .foregroundStyle(placeholderInk)
                    .padding(.leading, lead)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: lineHeight, maxHeight: lineHeight * CGFloat(maxLines))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var editor: some View {
        let base = TextEditor(text: $text)
            .font(.system(size: size))
            .foregroundStyle(ink)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .background(Color.clear)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                    return .ignored
                }
                onSubmit()
                return .handled
            }
        if let focus { base.focused(focus) } else { base }
    }

    /// How tall the box draws for `text`, for the island's height arithmetic.
    static func height(_ text: String, size: CGFloat = 13, lineHeight: CGFloat = 17,
                       maxLines: Int, width: Double,
                       wraps: (String, Double, Double) -> Int) -> CGFloat {
        let lines = text.isEmpty ? 1 : max(wraps(text, width - 10, Double(size)),
                                          text.components(separatedBy: "\n").count)
        return lineHeight * CGFloat(min(max(lines, 1), maxLines))
    }
}
