import AppKit
import SwiftUI

/// The mark beside a connection.
///
/// Every non-Apple service used to render as the same accent-tinted letter
/// tile, so Slack, Notion, Stripe and Figma were visually identical. The
/// comment explaining it was honest — "no brand art to ship or keep current" —
/// but it made the most-used screen in the app unscannable.
///
/// Three tiers, in order:
///
/// 1. **Real art**, from `ServiceIcons/` inside the app bundle. Bundled rather
///    than fetched: pulling each service's favicon at runtime would tell every
///    one of those domains which tools you use, one request at a time, and
///    would break offline. PNG, SVG or PDF — `NSImage` reads all three, and
///    the handful that come from Simple Icons are vectors.
/// 2. **An SF Symbol** for the Mac's own sources, which have no third-party
///    brand and never will.
/// 3. **A monogram in the service's own colour** — the fallback, and what the
///    long tail of the Hermes catalogue gets. A new MCP server that nobody has
///    drawn a mark for still arrives looking deliberate rather than broken.
///
/// Tier 1 is full: `Resources/ServiceIcons/` holds 213 marks, 1.1 MB, each
/// fetched once and committed — `scripts/fetch-service-icons.py` for the
/// Hermes catalogue (the service's own press kit or favicon), and
/// `scripts/fetch-service-icons.sh` for the brokered ones (Composio's logo
/// endpoint, which serves the company's own mark as SVG). Adding one is
/// dropping a file in that folder — `build.sh` copies it and this finds it
/// by name, which is why brokered marks are saved under the toolkit slug.
///
/// Every service the Connections pane lists before you search has one; that
/// is checked, not hoped for, by `scripts/test-connections-ui.sh`.
public enum ServiceIcons {
    /// `nil` when nothing is bundled for this service — the long tail of the
    /// Hermes catalogue, which falls through to a monogram. Cached: this is
    /// called for every row on every redraw.
    public static func art(for name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        let found = load(name)
        cache[name] = found
        return found
    }

    private static var cache: [String: NSImage?] = [:]

    /// Where the marks live, for both binaries that draw them.
    ///
    /// The app finds them through `Bundle.main`. The confirmation dialog is a
    /// second executable inside the same bundle with an Info.plist of its own,
    /// so `Bundle.main` is the dialog, not Memoe.app — and the marks are three
    /// directories up. Without the second path every service in that dialog
    /// falls back to a coloured monogram, which looks deliberate and is wrong.
    ///
    /// The third path is the repo, and it is there because of what it cost.
    /// A `swift build` binary is not in a bundle, so neither of the first two
    /// resolves, and `Moe --settings-snapshot` — the tool whose whole job is
    /// "look at the pane before you believe it" — rendered every third-party
    /// row as a coloured letter. The picture is not empty and not an error;
    /// it is a plausible screenshot of the wrong thing, which is the worst
    /// kind. Walking up from the executable to a checkout costs four
    /// `FileManager` hits at launch and never resolves inside `/Applications`.
    private static let searchPaths: [URL] = {
        var paths: [URL] = []
        if let bundled = Bundle.main.resourceURL {
            paths.append(bundled.appendingPathComponent("ServiceIcons"))
        }
        // …/Memoe.app/Contents/MacOS/moe-confirm → …/Memoe.app/Contents/Resources
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        paths.append(contents.appendingPathComponent("Resources/ServiceIcons"))
        // …/<repo>/.build/debug/Moe → …/<repo>/Resources/ServiceIcons
        var up = executable.deletingLastPathComponent()
        for _ in 0..<4 {
            up = up.deletingLastPathComponent()
            let candidate = up.appendingPathComponent("Resources/ServiceIcons")
            if FileManager.default.fileExists(atPath: candidate.path) {
                paths.append(candidate)
                break
            }
        }
        return paths
    }()

    private static func load(_ name: String) -> NSImage? {
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        // PNG for the favicons themselves; SVG for the many that come as
        // vectors — Simple Icons, and Composio's own logo endpoint, which
        // serves the brokered services' marks as SVG (NSImage renders it);
        // PDF if we ever hand-place vector art.
        //
        // `jpg` is here because scripts/fetch-service-icons.sh has always
        // been willing to WRITE one — its mime sniff has an `image/jpeg`
        // branch — and this list did not read it. A mark saved that way was
        // a file on disk that resolved to nothing, and the row drew a
        // monogram as though no logo had ever been fetched.
        for directory in searchPaths {
            for ext in ["png", "svg", "pdf", "jpg"] {
                let url = directory.appendingPathComponent("\(safe).\(ext)")
                if let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }

    /// Each service's own colour, so the monogram fallback still tells them
    /// apart. Taken from the brands' public marks; used only as a tint behind
    /// a letter, never to reproduce a logo.
    public static func tint(for name: String, label: String) -> Color {
        if let known = brand[name] { return known }
        // Anything unknown gets a stable colour derived from its name rather
        // than one shared accent — two adjacent rows in the long tail should
        // still look like different things.
        return derived(from: label.isEmpty ? name : label)
    }

    private static let brand: [String: Color] = [
        "slack": Color(hex: 0x4A154B),
        "notion": Color(hex: 0x1C1B17),
        "gmail": Color(hex: 0xD24334),
        "github": Color(hex: 0x1C1B17),
        "gitlab": Color(hex: 0xE24329),
        "linear": Color(hex: 0x5E6AD2),
        "stripe": Color(hex: 0x635BFF),
        "figma": Color(hex: 0xA259FF),
        "dropbox": Color(hex: 0x0061FE),
        "todoist": Color(hex: 0xE44332),
        "asana": Color(hex: 0xF06A6A),
        "atlassian": Color(hex: 0x0052CC),
        "telegram": Color(hex: 0x2AABEE),
        "whatsapp": Color(hex: 0x25D366),
        "teams": Color(hex: 0x5059C9),
        "drive": Color(hex: 0x1FA463),
        "drive-docs": Color(hex: 0x1A73E8),
        "chrome": Color(hex: 0x4285F4),
        "calendar": Color(hex: 0xD24334),
        "reminders": Color(hex: 0x5E6AD2),
        "notes": Color(hex: 0xE8B96B),
        "imessage": Color(hex: 0x25D366),
        "mail": Color(hex: 0x1E88E5),
        "calls": Color(hex: 0x4E7A52),
    ]

    /// Apple's own apps get an SF Symbol rather than a fetched icon: it says
    /// what the source *is* far better than five copies of the Apple logo
    /// would. Third-party brands read here as `nil` and fall through to their
    /// real mark — Gmail is a Mac-kind row but it is still Gmail.
    public static func macSymbol(for name: String) -> String {
        switch name {
        case "calendar": return "calendar"
        case "reminders": return "checklist"
        case "notes": return "note.text"
        case "call-recordings": return "waveform.circle"
        case "imessage": return "message"
        case "calls": return "phone"
        case "gmail", "mail": return "envelope"
        case "drive": return "externaldrive"
        // The disk beside it is the synced folder; this row is the documents
        // inside, so: a document.
        case "drive-docs", "drive-docs-pick": return "doc.text"
        case "chrome": return "safari"
        case "telegram": return "paperplane"
        case "whatsapp": return "bubble.left.and.bubble.right"
        default: return "laptopcomputer"
        }
    }

    /// A stable hue per name. Deterministic, so a row does not change colour
    /// between launches, and kept away from the reds and greens that mean
    /// something in this app.
    private static func derived(from text: String) -> Color {
        var hash: UInt64 = 5381
        for byte in text.lowercased().utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        // 200°–320°: blues through violets. Status colours own red and green.
        let hue = 200.0 + Double(hash % 120)
        return Color(hue: hue / 360, saturation: 0.42, brightness: 0.62)
    }
}

/// The 28pt mark drawn on a connection row.
public struct ServiceIcon: View {
    public let name: String
    public let label: String
    /// Mac-native sources get an SF Symbol rather than a monogram — they are
    /// the machine's own, not a brand.
    public var macSymbol: String?
    public var size: CGFloat = 28

    /// Written out rather than synthesised: a memberwise initialiser is
    /// internal, and this view is drawn from two modules now — Connections
    /// inside the app, and the send-confirmation dialog, which is its own
    /// process.
    public init(name: String, label: String, macSymbol: String? = nil, size: CGFloat = 28) {
        self.name = name
        self.label = label
        self.macSymbol = macSymbol
        self.size = size
    }

    public var body: some View {
        Group {
            if let art = ServiceIcons.art(for: name) {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.62, height: size * 0.62)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.glyph, style: .continuous)
                            .fill(Theme.sunk)
                    )
            } else if let macSymbol {
                Image(systemName: macSymbol)
                    .font(.system(size: size * 0.5, weight: .regular))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.glyph, style: .continuous)
                            .fill(Theme.sunk)
                    )
            } else {
                let tint = ServiceIcons.tint(for: name, label: label)
                Text(String(label.prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.glyph, style: .continuous)
                            .fill(tint)
                    )
            }
        }
    }
}
