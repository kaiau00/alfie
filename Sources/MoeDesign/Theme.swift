import SwiftUI
import AppKit

/// The design system. One place where every colour, size, radius and duration
/// in the app is named.
///
/// Before this file the app had no token layer at all: the main window was
/// stock `Form`/`List` inheriting whatever the system accent happened to be,
/// and the island carried sixteen inline `Color(red:green:blue:)` literals.
/// Two surfaces, no shared vocabulary, and light mode was whatever fell out.
///
/// Three rules hold this together:
///
/// 1. **Nothing is a literal at the call site.** If a view names a hex value,
///    it belongs here instead.
/// 2. **Light and dark are each designed, not inverted.** Every colour below
///    is a `dynamic(light:dark:)` pair with both halves chosen by hand. The
///    accent is the clearest case: it gets *darker* on paper so it can carry a
///    button, and *lighter* on the dark ground so it doesn't disappear. An
///    inversion cannot produce that.
/// 3. **Every neutral is warm.** There is no cool grey in the light palette.
///    That single constraint does most of the work separating "elegant" from
///    "technical", and it is easy to undo by accident.
public enum Theme {

    // MARK: - Ground

    /// The window ground: the same paper as moebot.app. A neutral white here
    /// reads as clinical and is the thing that makes software look like a
    /// control panel.
    public static let paper = dynamic(light: 0xF6F1E5, dark: 0x16130F)

    /// Content panels sitting on `paper`. Lighter in light mode, *lighter* in
    /// dark mode too — raised means raised in both, which is why this is not
    /// an inversion.
    public static let raised = dynamic(light: 0xFDFAF1, dark: 0x1C1813)

    /// Recessed wells: code blocks, expanded tool detail, the sheet backdrop.
    public static let sunk = dynamic(light: 0xECE5D4, dark: 0x110F0C)

    /// The sidebar, which sits a step back from the content panel it borders.
    public static let sidebar = dynamic(light: 0xECE5D4, dark: 0x120F0C)

    // MARK: - Ink

    /// Primary text.
    public static let ink = dynamic(light: 0x241C12, dark: 0xF1EADB)
    /// Secondary text: running prose, captions that still need to be read.
    public static let ink2 = dynamic(light: 0x665A4A, dark: 0xB3A892)
    /// Tertiary text: labels, timestamps, things scanned rather than read.
    public static let ink3 = dynamic(light: 0x8F8270, dark: 0x7F7462)

    // MARK: - Rules
    //
    // Borders, not shadows. Wispr's house style and the reason their surfaces
    // read as crisp rather than floating — a 2px rule states an edge that a
    // soft shadow only implies. Shadows survive here only on the window itself
    // and on sheets, where real elevation is being described.

    /// Hairline separators inside a panel.
    public static let rule = dynamic(light: 0xDED4BF, dark: 0x2F2921)
    /// The 2px borders that carry cards, the composer and sheets.
    public static let ruleStrong = dynamic(light: 0xC9BDA3, dark: 0x3E362C)

    // MARK: - Accent
    //
    // The slate from moebot.app (2026-09-18, the facelift): the site's one
    // accent, with the lightness moved so it works on each ground. The app
    // and the page it was downloaded from are now one palette — paper
    // #F6F1E5, ink #241C12, slate #3F5670 — and the periwinkle that used to
    // live here survives only in the app icon.

    /// Filled buttons, selection, the active sidebar row.
    public static let accent = dynamic(light: 0x3F5670, dark: 0x8FB0D1)
    /// Links and text on the accent's own tint, where `accent` lacks contrast.
    public static let accentDeep = dynamic(light: 0x2F4256, dark: 0xB5CDE3)
    /// Selection washes and quiet accent surfaces.
    public static let accentTint = dynamic(light: 0xE1E7EE, dark: 0x24303C)

    /// Text drawn *on top of* a filled `accent` surface. Not white in dark
    /// mode: the dark accent is light enough that white on it is unreadable.
    public static let onAccent = dynamic(light: 0xF6F1E5, dark: 0x16130F)

    // MARK: - Status
    //
    // Semantic, and deliberately the only other colour in the app. If
    // something here is being used for decoration it is being used wrongly.

    /// A connection that genuinely answered — `doctor.sh` proved it.
    public static let good = dynamic(light: 0x4E7A52, dark: 0x7FB184)
    /// Needs a human: a permission to grant, a token to paste.
    public static let warn = dynamic(light: 0xB07D29, dark: 0xD9A94F)
    /// Recording, and failure.
    public static let bad = dynamic(light: 0xB0453C, dark: 0xE0736A)

    /// Meeting transcript attribution. Mic and system audio give us you/them
    /// for free, so the two channels are coloured rather than labelled.
    public static let you = dynamic(light: 0x3F7A5C, dark: 0x8FD0A8)
    public static let them = dynamic(light: 0x4A6FA8, dark: 0x94B3E8)

    /// Your side of a chat. The accent's own tint, so what you said reads as
    /// yours at a glance, and Moe's plain ground reads as the other voice.
    public static let bubble = dynamic(light: 0xE1E7EE, dark: 0x24303C)
    /// The bubble's edge — one step deeper than its fill, as every edge here is.
    public static let bubbleRule = dynamic(light: 0xC9D4DF, dark: 0x35475A)

    // MARK: - Interaction

    /// Row hover. Ink at 4% on paper, white at 5% on dark — the asymmetry is
    /// deliberate, light-on-dark needs slightly more to register.
    public static let hover = dynamic(light: 0x241C12, lightAlpha: 0.04,
                               dark: 0xFFFFFF, darkAlpha: 0.05)
    /// Row selection.
    public static let selected = dynamic(light: 0x3F5670, lightAlpha: 0.13,
                                  dark: 0x8FB0D1, darkAlpha: 0.16)

    // MARK: - The island
    //
    // Fixed, in both appearances. The island floats over the physical notch
    // and whatever wallpaper is behind it, so it is not describing the app's
    // surface — it is describing the machine's. Dark is correct there even
    // when the window is on paper. These replace the sixteen literals that
    // used to live in IslandView.

    public enum Island {
        public static let ground = Color(hex: 0x0C0B09)
        public static let ink = Color(hex: 0xEFECE2)
        public static let ink2 = Color(hex: 0xCFCABC)
        public static let ink3 = Color(hex: 0x9B958A)
        public static let rule = Color.white.opacity(0.07)

        /// Recording. Warmer than the old 1.0/0.23/0.2, which read as an alert.
        public static let recording = Color(hex: 0xE26055)
        /// Attention, action items, the nudge bar.
        public static let amber = Color(hex: 0xE8A64A)
        /// Dictation. Lavender, and unlike anything the agent shows — the glow
        /// alone has to say "this is going to the cursor, not to Moe".
        public static let dictation = Color(hex: 0xB79AF5)
        /// Moe has your screen: it is clicking and typing in an app right now.
        ///
        /// MAGENTA, and the hue was measured rather than chosen by eye. The
        /// first attempt at this was a teal, 0x3FC8B4, described in this very
        /// comment as "unmistakable against every other state". It was 14°
        /// from `speaking` and 27° from `listening`, and the owner's report
        /// was simply "my thing is green now".
        ///
        /// The palette in hue order: recording 5°, amber 35°, you 143°,
        /// listening 144°, speaking 158°, thinking 204°, idle 210°, them
        /// 218°, dictation 259°. Everything from 143 to 218 is one crowded
        /// band of greens and blues, and the only real gap left is 300-340.
        /// This sits at 328° — 36° from its nearest neighbour, the largest
        /// separation available. Orange would have been 11° from amber and a
        /// violet 1° from dictation; both are worse than the teal was.
        public static let driving = Color(hex: 0xFF3FA4)

        public static let you = Color(hex: 0x8FD0A8)
        public static let them = Color(hex: 0x94B3E8)

        /// Moe's own speaker label in the island transcript. Cyan, kept
        /// clearly apart from `them` — during a meeting both are on screen at
        /// once and a reply must never be mistaken for the far end.
        public static let moe = Color(hex: 0x6FC9E8)
        /// The one link in the nudge bar.
        public static let link = Color(hex: 0xE8B96B)

        /// The notch no longer glows (2026-10-15, `IslandEars`): these two are
        /// what is left of the glow palette. `listening` tints your words in
        /// the open panel while you are still saying them; `moeLight` is the
        /// status dot beside the notch.
        public static let listening = Color(hex: 0x59D98C)
        public static let moeLight = Color(hex: 0xF4F2EC)
    }

    // MARK: - Type
    //
    // One family, the system sans, at three roles: display for titles, prose
    // for what a person reads, ui for what a person operates. Mono only where
    // digits line up. The facelift (2026-09-18) retired the serif: moebot.app
    // is set in a sans, and the app is the same object as the page it came
    // from. Hierarchy comes from size and weight, not from a second family.

    public enum Typo {
        /// Section titles and empty states. Semibold, tight: the site's h1.
        public static func display(_ size: CGFloat = 30) -> Font {
            .system(size: size, weight: .semibold)
        }

        /// Sheet and panel headings.
        public static func heading(_ size: CGFloat = 19) -> Font {
            .system(size: size, weight: .semibold)
        }

        /// Running prose: Moe's replies, meeting notes, memory, dictation
        /// transcripts. Everything a person actually reads.
        public static func prose(_ size: CGFloat = 15) -> Font {
            .system(size: size, weight: .regular)
        }

        /// Chrome: buttons, rows, fields, anything operated.
        public static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        /// Uppercase micro-labels. Pair with `Theme.tracking` — SwiftUI has no
        /// letter-spacing on `Font`, it is a `.tracking()` modifier on the view.
        public static func label(_ size: CGFloat = 10) -> Font {
            .system(size: size, weight: .semibold)
        }

        /// Clocks, durations, counts, file sizes. Tabular so columns align.
        public static func data(_ size: CGFloat = 11) -> Font {
            .system(size: size, weight: .regular, design: .monospaced)
        }
    }

    /// Letter-spacing for uppercase labels. Uppercase without tracking looks
    /// cramped at every size; this is the one place the app spaces type out.
    public static let tracking: CGFloat = 1.1

    /// Light-on-dark type optically blooms, so display and button weights step
    /// up one notch on the dark ground. Invisible when it is working and
    /// obvious when it is missing.
    public static func weight(_ base: Font.Weight, for scheme: ColorScheme) -> Font.Weight {
        guard scheme == .dark else { return base }
        switch base {
        case .regular:  return .medium
        case .medium:   return .semibold
        case .semibold: return .bold
        default:        return base
        }
    }

    // MARK: - Geometry

    public enum Radius {
        /// The window itself.
        public static let window: CGFloat = 14
        /// The content panel inset inside the window.
        public static let panel: CGFloat = 11
        /// Cards and the composer.
        public static let card: CGFloat = 14
        /// Sheets — the most generous radius in the app.
        public static let sheet: CGFloat = 22
        /// Buttons, fields, the search bar.
        public static let control: CGFloat = 10
        /// Sidebar rows and small tiles.
        public static let row: CGFloat = 8
        /// Service marks in Connections.
        public static let glyph: CGFloat = 7
        /// Pills and chips.
        public static let pill: CGFloat = 999
    }

    /// One spacing scale. Anything not on it is a mistake worth questioning.
    public enum Space {
        public static let hair: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 6
        public static let small: CGFloat = 8
        public static let base: CGFloat = 12
        public static let cosy: CGFloat = 16
        public static let roomy: CGFloat = 20
        public static let wide: CGFloat = 24
        public static let section: CGFloat = 32
        public static let generous: CGFloat = 40
        public static let vast: CGFloat = 56
    }

    /// Border widths. 2px is the house style for anything that states an edge;
    /// 1px is for separators inside a surface that is already bounded.
    public enum Stroke {
        public static let hair: CGFloat = 1
        public static let edge: CGFloat = 2
    }

    /// Running prose is capped near 60 characters. At 15pt that is
    /// roughly this many points — the single most effective thing you can do
    /// to make a wide window feel composed rather than sprawling.
    public static let measure: CGFloat = 560

    // MARK: - Motion
    //
    // Hover changes colour, never position or scale. Every reference agrees on
    // this and it is the difference between "considered" and "bouncy".

    public enum Motion {
        /// Hover and press feedback — fast enough to feel like the cursor.
        public static let fast: Double = 0.06
        /// The default. Colour transitions, disclosure, selection.
        public static let base: Double = 0.2
        /// Panels arriving, sheets, the island expanding.
        public static let slow: Double = 0.45

        public static let easeOut = SwiftUI.Animation.timingCurve(0.165, 0.84, 0.44, 1, duration: base)
        public static let snap = SwiftUI.Animation.timingCurve(0.32, 0.72, 0, 1, duration: slow)
    }

    // MARK: - Elevation
    //
    // Light describes elevation with an outer hairline ring plus a soft
    // shadow. Dark cannot — a soft shadow is invisible against a dark ground —
    // so it uses an inset ring and one deeper shadow instead. Same intent,
    // different technique, which is again why the two themes are designed
    // rather than derived.

    /// Shadow for the window and for sheets.
    public static func windowShadow(_ scheme: ColorScheme) -> (Color, CGFloat, CGFloat) {
        scheme == .dark
            ? (.black.opacity(0.50), 30, 12)
            : (Color(hex: 0x241C12).opacity(0.11), 22, 9)
    }

    // MARK: - Plumbing

    /// An appearance-aware colour. `NSColor`'s dynamic provider is what makes
    /// this follow the system setting without any view needing to know.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamic(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
    }

    private static func dynamic(light: UInt32, lightAlpha: Double,
                                dark: UInt32, darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

// MARK: - Hex

extension Color {
    /// 0xRRGGBB. Only Theme should be calling this — a hex literal anywhere
    /// else is a token that has not been named yet.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
