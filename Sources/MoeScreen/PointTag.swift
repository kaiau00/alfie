import Foundation

/// One `[POINT:x,y:label]` the model wrote into its reply: a spot on the
/// screenshot it was shown, in that screenshot's pixels (origin top-left),
/// with a few words to show beside it. Modelled on farzaa/clicky (MIT),
/// which uses the same tag to fly its cursor; clicky's optional fourth
/// field, `:screenN`, is accepted and kept as `screen`.
public struct PointTag: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let label: String
    public let screen: Int?

    public init(x: Int, y: Int, label: String, screen: Int? = nil) {
        self.x = x; self.y = y; self.label = label; self.screen = screen
    }
}

/// Pulls `[POINT:…]` tags out of a reply as it streams, handing back the
/// text with the tags removed (so nothing is spoken or shown) and the tags
/// themselves.
///
/// Deltas split anywhere — `"[PO"` then `"INT:12,34:Save]"` — so anything
/// from an unmatched `[` that could still become a tag is held back until
/// the next delta settles it. Text that turns out not to be a tag
/// (`[sic]`, a stray bracket, `[POINT:nope]`) is released unchanged. A
/// label may contain brackets of its own (`the [Save] button`): the tag
/// ends at the first `]` that closes the opening one.
public struct PointTagParser: Sendable {
    private static let prefix = "[POINT:"
    /// An open `[POINT:` with no `]` in sight after this many characters is
    /// not a tag the model is still writing; release it as text.
    private static let maxHold = 300

    private var held = ""
    /// The last character handed out, across deltas, so the whitespace
    /// around a removed tag collapses even when the tag straddles a delta.
    private var lastEmitted: Character?
    /// A tag ended the previous delta: the whitespace that opens the next
    /// one is the tag's trailing space and goes with it.
    private var pendingCollapse = false

    public init() {}

    /// Feed the next delta. Returns the text to append (which may lag the
    /// input while a possible tag is pending) and any tags completed.
    public mutating func feed(_ delta: String) -> (text: String, tags: [PointTag]) {
        var buf = held + delta
        held = ""
        var out = ""
        var tags: [PointTag] = []
        if pendingCollapse, let first = buf.first {
            pendingCollapse = false
            if first.isWhitespace, lastEmitted == nil || lastEmitted == first { buf.removeFirst() }
        }

        while !buf.isEmpty {
            guard let open = buf.firstIndex(of: "[") else {
                out += buf
                break
            }
            out += buf[..<open]
            let rest = String(buf[open...])

            // Not (yet) a tag: pass the bracket through, or hold a prefix.
            if rest.count < Self.prefix.count {
                if Self.prefix.hasPrefix(rest) { held = rest; buf = ""; break }
                out += "["; buf = String(rest.dropFirst()); continue
            }
            guard rest.hasPrefix(Self.prefix) else {
                out += "["; buf = String(rest.dropFirst()); continue
            }

            // Find the `]` that closes this `[`, skipping nested pairs.
            let body = rest.index(rest.startIndex, offsetBy: Self.prefix.count)
            var depth = 0
            var close: String.Index?
            var i = body
            while i < rest.endIndex {
                let c = rest[i]
                if c == "[" { depth += 1 }
                else if c == "]" {
                    if depth == 0 { close = i; break }
                    depth -= 1
                }
                i = rest.index(after: i)
            }
            guard let close else {
                if rest.count > Self.maxHold {
                    out += "["; buf = String(rest.dropFirst()); continue
                }
                held = rest; buf = ""; break
            }

            guard let tag = Self.parse(String(rest[body..<close])) else {
                out += "["; buf = String(rest.dropFirst()); continue
            }
            tags.append(tag)
            var after = String(rest[rest.index(after: close)...])
            // "here [POINT:…] to" → "here to", not "here  to"; and no
            // leading space when the tag opened the reply.
            if let next = after.first {
                let before = out.last ?? lastEmitted
                if next.isWhitespace, before == nil || before == next { after.removeFirst() }
            } else {
                pendingCollapse = true
            }
            buf = after
        }
        if let last = out.last { lastEmitted = last }
        return (out, tags)
    }

    /// The end of the reply: whatever was held back and never became a tag.
    public mutating func flush() -> String {
        defer { held = "" }
        return held
    }

    /// Everything the parser would return for `text` in one go, tags removed.
    public static func strip(_ text: String) -> String {
        var p = PointTagParser()
        let (out, _) = p.feed(text)
        return out + p.flush()
    }

    /// All tags in a complete text.
    public static func tags(in text: String) -> [PointTag] {
        var p = PointTagParser()
        return p.feed(text).tags
    }

    /// `x,y:label[:screenN]` → tag, or nil when it is not one.
    private static func parse(_ inner: String) -> PointTag? {
        let fields = inner.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard let coords = fields.first else { return nil }
        let xy = coords.split(separator: ",", omittingEmptySubsequences: false)
        guard xy.count == 2,
              let x = number(xy[0]), let y = number(xy[1]) else { return nil }
        let label = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
        var screen: Int?
        if fields.count > 2 {
            let s = fields[2].trimmingCharacters(in: .whitespaces)
            guard s.lowercased().hasPrefix("screen"), let n = Int(s.dropFirst(6)) else { return nil }
            screen = n
        }
        return PointTag(x: x, y: y, label: label, screen: screen)
    }

    private static func number(_ s: Substring) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let i = Int(t) { return i }
        if let d = Double(t), d.isFinite { return Int(d.rounded()) }
        return nil
    }
}
