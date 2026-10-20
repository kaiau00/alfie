import AppKit
import MoeIsland

/// AppKit's answer to "how many lines does this take", for
/// `ConversationPanel.height`, which cannot see a font.
///
/// A character count was close enough for the notes panel's body, which
/// scrolls. The rows this measures do not scroll: a line under-counted here
/// is the ask field pushed off the bottom of the panel, so they are measured
/// with the system font the view draws them in.
enum IslandTextMeasure {

    static let wraps: ConversationPanel.Wraps = { text, width, size in
        lines(text, width: width, size: size)
    }

    static func lines(_ text: String, width: Double, size: Double,
                      weight: NSFont.Weight = .regular) -> Int {
        guard width > 0 else { return 1 }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return max(Int((rect.height / line).rounded()), 1)
    }

    /// One line's width, for a pill whose label decides its size.
    static func width(_ text: String, size: Double, weight: NSFont.Weight = .regular) -> Double {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
