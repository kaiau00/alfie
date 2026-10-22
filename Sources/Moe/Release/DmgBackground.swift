import AppKit
import MoeDesign
import SwiftUI

/// The picture behind the disk image's Finder window — the first thing a
/// downloader sees.
///
/// `Moe --dmg-background <png>` renders it; `scripts/release.sh` puts it in
/// the image and `scripts/dmg-layout.sh` tells Finder to show it, with the
/// app on the left, Applications on the right, and the arrow between them
/// drawn here.
///
/// It used to carry three numbered steps for getting past Gatekeeper —
/// "click Done, not Move to Trash", "Privacy & Security › Open Anyway" —
/// because that is what opening an unsigned Moe took. Since 0.3.15 the app is
/// signed with a Developer ID and notarized, the first open is one ordinary
/// dialog and one click, and those steps described something that no longer
/// happens. **This file is a picture, so `scripts/test-first-open.sh` cannot
/// read its words** — which is exactly how it went on saying them after the
/// other four places were corrected. A retired-wording test in the private
/// tree greps the source instead. Nothing here may contradict docs/FIRST-OPEN.md,
/// which remains the one place that wording lives.
///
/// What is left is the only instruction the window ever really needed: the
/// gesture. The arrow says it; the text names it once and stops.
///
/// 660 × 400 points of window CONTENT — `dmg-layout.sh` opens the window
/// 37 points taller, because Finder's window bounds include the title bar
/// and the first cut of this lost its bottom line to it. Rendered on a
/// Retina Mac the PNG is 1320 × 800 pixels at 144 dpi, which Finder scales
/// back to the window. The icon slots below are in content points and must
/// match the positions the layout script sets; a 128-point icon's label
/// sits about 75–95 points below its centre, and the words start under
/// that.
enum DmgBackground {
    static let size = CGSize(width: 660, height: 400)
    /// Where the layout script puts the two icons (their centres), and the
    /// icon size it sets. The arrow is drawn between them.
    static let appSlot = CGPoint(x: 165, y: 118)
    static let applicationsSlot = CGPoint(x: 495, y: 118)
    static let iconSize: CGFloat = 128

    @MainActor
    static func write(to path: String) -> Bool {
        // AppKit's text stack wants an application object; this creates one
        // and starts no run loop (the same line SettingsSnapshot.run has).
        _ = NSApplication.shared
        return SettingsSnapshot.write(View(), to: path, size: size, appearance: .aqua)
    }

    struct View: SwiftUI.View {
        var body: some SwiftUI.View {
            ZStack(alignment: .top) {
                Theme.raised
                arrow
                // Under the icon labels, centred. One instruction, said once,
                // large enough to read from across a desk — and a quieter
                // line under it for what happens next.
                VStack(alignment: .center, spacing: 7) {
                    Text("Drag Alfie onto Applications")
                        .font(Theme.Typo.ui(21, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Then open it from there.")
                        .font(Theme.Typo.ui(14, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                }
                .multilineTextAlignment(.center)
                .frame(width: 580)
                // Three numbered steps used to start here. With one line and a
                // subtitle in their place, the block sits a little lower so it
                // is centred in the space under the icons rather than crowding
                // their labels.
                .padding(.top, 250)
            }
            .frame(width: DmgBackground.size.width, height: DmgBackground.size.height)
        }

        /// From the app's icon to the Applications folder: a quiet line with a
        /// head, in the rule colour, so it reads as "put this there" and not
        /// as a button.
        private var arrow: some SwiftUI.View {
            let y = DmgBackground.appSlot.y
            let half = DmgBackground.iconSize / 2
            let from = DmgBackground.appSlot.x + half + 18
            let to = DmgBackground.applicationsSlot.x - half - 18
            return Path { p in
                p.move(to: CGPoint(x: from, y: y))
                p.addLine(to: CGPoint(x: to, y: y))
                p.move(to: CGPoint(x: to - 14, y: y - 11))
                p.addLine(to: CGPoint(x: to, y: y))
                p.addLine(to: CGPoint(x: to - 14, y: y + 11))
            }
            .stroke(Theme.ruleStrong, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}
