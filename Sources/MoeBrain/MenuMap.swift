import Foundation

/// An app's menu bar, as a list of paths the agent can invoke.
///
/// `computer_use invoke_menu` can fire any menu item by exact path, through
/// the accessibility API — no screenshot, no coordinates, and it fails closed
/// rather than clicking somewhere hopeful. But it can only invoke a path it
/// can already name, and nothing enumerates them: cua-driver's
/// `get_window_state` is scoped to a *window*, and an app's menu bar is not in
/// any window. So the capability existed with no way to discover its input,
/// and the model was left guessing exact labels.
///
/// That gap matters most exactly where menus matter most. A DAW, a CAD app or
/// a 3D tool draws its canvas as one custom surface that exposes no
/// accessibility tree at all — the pixels are all there is — while its menu
/// bar is ordinary AppKit and completely enumerable. "Bounce the track" is
/// unreachable by element and one path away by menu.
///
/// The parsing and formatting live here, away from the AX API, so the
/// shortcut rendering is tested without an app, a display or a permission
/// grant. `AppMenus` does the walking.
public enum MenuMap {

    /// One invocable item.
    public struct Item: Equatable, Sendable {
        /// Full path from the menu-bar title down, e.g. ["File", "Export…"].
        /// This is exactly what `invoke_menu` takes.
        public var path: [String]
        /// The keyboard shortcut, when the menu shows one — "⌘B".
        public var shortcut: String?
        /// Disabled items are listed rather than hidden: knowing that "Bounce"
        /// exists but is greyed out is the answer to "why did nothing happen",
        /// and it is a different answer from "there is no such item".
        public var enabled: Bool

        public init(path: [String], shortcut: String? = nil, enabled: Bool = true) {
            self.path = path
            self.shortcut = shortcut
            self.enabled = enabled
        }
    }

    /// Modifier bits as AX reports them in `AXMenuItemCmdModifiers`.
    ///
    /// Two traps, and a first draft of this got both wrong in a way no unit
    /// test could catch, because the constants were invented rather than
    /// measured. Verified against Finder's own menu bar:
    ///
    ///     Settings…          ⌘,     mods=0
    ///     Empty Trash…       ⇧⌘⌫    mods=1
    ///     Hide Others        ⌥⌘H    mods=2
    ///     New Folder         ⇧⌘N    mods=1
    ///
    /// So: **shift is bit 0**, option bit 1, control bit 2 — and the
    /// *command* bit is inverted. It is set when Command is ABSENT, because a
    /// bare ⌘ is the default for a menu shortcut and the flag records the
    /// departure from it. `mods=0` means plain ⌘, not "no modifiers".
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift     = Modifiers(rawValue: 1 << 0)
        public static let option    = Modifiers(rawValue: 1 << 1)
        public static let control   = Modifiers(rawValue: 1 << 2)
        public static let noCommand = Modifiers(rawValue: 1 << 3)
        /// The Globe / fn key, macOS Sequoia's window-management modifier.
        ///
        /// Measured across eight running apps: 113 of 679 shortcut-bearing
        /// items carry this bit, and every one of them is a Globe shortcut —
        /// "Enter Full Screen" is 🌐F, "Window › Center" is 🌐⌃C. A first
        /// draft knew only bits 0–3 and printed those as ⌘F and ⌃C, which are
        /// different shortcuts that do different things.
        public static let globe     = Modifiers(rawValue: 1 << 4)

        /// Everything outside the mask this build understands.
        static let known: Modifiers = [.shift, .option, .control, .noCommand, .globe]
        var hasUnknownBits: Bool { !Modifiers(rawValue: rawValue & ~Modifiers.known.rawValue).isEmpty }
    }

    /// Render a shortcut the way the menu itself draws it.
    ///
    /// Order matches Apple's: control, option, shift, command — the same
    /// order a person reads off the menu, so a printed shortcut can be
    /// compared against a screenshot by eye.
    ///
    /// Returns nil when there is no shortcut at all, which is most items.
    public static func shortcut(key: String?, modifiers rawModifiers: Int?,
                                virtualKey: Int? = nil) -> String? {
        let mods = Modifiers(rawValue: rawModifiers ?? 0)
        // An unrecognised modifier bit means this build cannot name the
        // shortcut. Say nothing rather than something wrong: the same policy
        // `virtualKeyName` follows, and for the same reason — a shortcut
        // printed wrong is acted on, one left out sends the agent to the menu
        // path, which works. This is exactly how the Globe key shipped as ⌘.
        if mods.hasUnknownBits { return nil }
        var glyph = ""
        if mods.contains(.globe)   { glyph += "🌐" }
        if mods.contains(.control) { glyph += "⌃" }
        if mods.contains(.option)  { glyph += "⌥" }
        if mods.contains(.shift)   { glyph += "⇧" }
        if !mods.contains(.noCommand) { glyph += "⌘" }

        if let key, let scalar = key.unicodeScalars.first, key.count == 1 {
            // AX hands back the RAW character, so ⌫ arrives as U+0008 and ↩ as
            // U+000D. Rendering those straight produced "Empty Trash… []" —
            // brackets around an invisible control character — on the first
            // real menu bar this was pointed at. Map the ones menus use.
            if let named = controlGlyph(scalar) {
                return glyph + named
            }
            // Cocoa's function-key range (NSUpArrowFunctionKey and friends)
            // is private-use, never printable.
            if !isPrintable(scalar) {
                return virtualKey.flatMap(virtualKeyName).map { glyph + $0 }
            }
            // Otherwise it is a real character; menus draw it uppercase.
            return glyph + key.uppercased()
        }
        if let key, !key.isEmpty, isPrintable(key.unicodeScalars.first!) {
            return glyph + key.uppercased()
        }
        // A function or arrow key carries no character, only a keycode.
        if let virtualKey, let named = virtualKeyName(virtualKey) {
            return glyph + named
        }
        // Modifiers with no key is not a shortcut. Returning the modifiers
        // alone printed "Empty Trash [⇧]", which reads as a real shortcut and
        // is not one.
        return nil
    }

    /// The control characters AX uses for keys that have a glyph, not a letter.
    static func controlGlyph(_ scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x08: return "⌫"       // backspace
        case 0x7F: return "⌦"       // forward delete
        case 0x0D: return "↩"       // return
        case 0x03: return "⌤"       // enter
        case 0x09: return "⇥"       // tab
        case 0x19: return "⇤"       // back-tab
        case 0x1B: return "⎋"       // escape
        case 0x20: return "Space"
        case 0x1C: return "←"
        case 0x1D: return "→"
        case 0x1E: return "↑"
        case 0x1F: return "↓"
        // U+0010 is AX's own placeholder for "there is no character here,
        // read the virtual keycode instead".
        default: return nil
        }
    }

    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        // Cocoa function keys live in the private-use area.
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        return true
    }

    /// The virtual keycodes that appear in menus. Not exhaustive by design —
    /// an unknown code yields no shortcut rather than a wrong one, because a
    /// shortcut printed wrong is worse than a shortcut left out: the first is
    /// acted on, the second sends the agent to the menu path, which works.
    static func virtualKeyName(_ code: Int) -> String? {
        switch code {
        case 0x7A: return "F1";  case 0x78: return "F2";  case 0x63: return "F3"
        case 0x76: return "F4";  case 0x60: return "F5";  case 0x61: return "F6"
        case 0x62: return "F7";  case 0x64: return "F8";  case 0x65: return "F9"
        case 0x6D: return "F10"; case 0x67: return "F11"; case 0x6F: return "F12"
        case 0x7B: return "←";   case 0x7C: return "→"
        case 0x7E: return "↑";   case 0x7D: return "↓"
        case 0x24: return "↩";   case 0x4C: return "⌤";   case 0x30: return "⇥"
        case 0x31: return "Space"; case 0x33: return "⌫"; case 0x75: return "⌦"
        case 0x35: return "⎋";   case 0x73: return "↖";   case 0x77: return "↘"
        case 0x74: return "⇞";   case 0x79: return "⇟"
        default: return nil
        }
    }

    /// Menu titles that are never worth listing.
    ///
    /// The Apple menu is the same on every app and belongs to the system, not
    /// the app being driven; separators carry no label at all.
    public static func isNoise(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "Apple"
    }

    /// Paths that appear more than once, with how many items share each.
    ///
    /// macOS lets two menu items carry the same title in the same menu, and
    /// AppKit uses it for ⌥-alternates: Finder's Go menu has `Enclosing
    /// Folder` twice, ⌘↑ and ⌥⌘↑. Measured on this Mac under `LC_ALL=C`,
    /// which matters — collating with a UTF-8 locale reported a third pair,
    /// `Empty Trash…` against `Empty Trash`, that differ by an ellipsis and
    /// are not the same item at all:
    ///
    ///     Finder    2 duplicated paths of 184 items
    ///     Notes     5              …    of 208
    ///     Terminal  1              …    of 201
    ///
    /// It is rare, and it is exactly the case `invoke_menu` refuses: the
    /// driver resolves one live level at a time and fails closed on an
    /// ambiguous segment. So an enumerator that does not mark these is
    /// advertising paths that cannot be invoked — the listing's whole job is
    /// to hand back something that round-trips.
    public static func ambiguousPaths(_ items: [Item]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.path.joined(separator: " > "), default: 0] += 1 }
        return counts.filter { $0.value > 1 }
    }

    /// A compact rendering for a prompt or a cache file.
    ///
    /// One line per item, path joined with " > " so it round-trips into
    /// `invoke_menu`, shortcut appended in brackets. Disabled items are marked
    /// rather than dropped, and so are ambiguous ones.
    ///
    /// `ambiguityFrom` exists because a search result is a subset: two items
    /// sharing a path always match a path query together, but a shortcut query
    /// can return one of a pair and nothing would say it had a twin. Pass the
    /// full listing and the marking stays true.
    public static func render(_ items: [Item], ambiguityFrom all: [Item]? = nil) -> String {
        let ambiguous = ambiguousPaths(all ?? items)
        return items.map { item -> String in
            let path = item.path.joined(separator: " > ")
            var line = path
            if let s = item.shortcut { line += "  [\(s)]" }
            if !item.enabled { line += "  (disabled)" }
            if let n = ambiguous[path] {
                // Name the way out, or say plainly that there is not one. An
                // ⌥-alternate almost always has a shortcut — that is what it
                // is for — and a shortcut is ordinary background input, so it
                // is a better rung than the menu anyway.
                line += item.shortcut != nil
                    ? "  (ambiguous: \(n) items share this path — invoke_menu"
                      + " refuses it; send the shortcut instead)"
                    : "  (ambiguous: \(n) items share this path and this one"
                      + " has no shortcut — it cannot be reached by path)"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Items whose path or shortcut mentions `query`, case-insensitively.
    ///
    /// A big app's menu bar runs to hundreds of items; handing all of them to
    /// a model costs more than the screenshot this replaces. Searching it is
    /// the point — "what is the shortcut for bounce" is one lookup.
    public static func search(_ items: [Item], for query: String) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            item.path.contains { $0.lowercased().contains(q) }
                || (item.shortcut?.lowercased().contains(q) ?? false)
        }
    }
}
