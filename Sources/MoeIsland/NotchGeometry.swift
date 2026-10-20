import CoreGraphics
import Foundation

/// Where the notch is, on whichever Mac this is.
///
/// Every notched Mac reports its cutout the same way — the menu bar's safe
/// area for the height, and the two strips of menu bar either side of it for
/// the width — but the numbers differ by model and by the scaled resolution
/// the person picked: a 13-inch Air measures 179 × 32 pt at its default, a
/// 14-inch Pro is published at 185 × 32, a 16-inch at 220 × 38 at "More
/// Space", and every Mac without one (the M1 Air, the MacBook Neo, an iMac,
/// any external display) reports nothing at all. The island hangs every one
/// of its shapes off this measurement, so it lives here, where each of those
/// machines can be a test instead of a guess.
///
/// Two things this fixes that the inline version did not:
///
///  - **Centring.** The window was centred on the screen, and the notch is
///    centred on the *menu bar strips*. On the 13-inch Air they are 646 and
///    645 pt, so the notch's centre is half a point right of the screen's:
///    enough to leave a hairline of bezel down one side of an open panel.
///  - **Which screen.** The notch was measured on the screen under the
///    cursor while the window lived on the screen it was first built on. With
///    an external display, a reply arriving while the cursor was out there
///    measured *no* notch and drew the panel's first 32 pt up inside the
///    camera housing of the laptop.
public struct NotchGeometry: Equatable, Sendable {
    /// The cutout, in points. Zero width on a Mac without one; the height can
    /// still be non-zero when a display reports a camera inset but no strips,
    /// so content is kept clear of it all the same.
    public let size: CGSize
    /// The cutout's horizontal centre, in global screen coordinates — the
    /// same space as `NSScreen.frame` — or the screen's centre without one.
    public let centreX: CGFloat

    public var hasNotch: Bool { size.width > 0 && size.height > 0 }

    public init(size: CGSize, centreX: CGFloat) {
        self.size = size
        self.centreX = centreX
    }

    /// The narrowest the resting hover target is ever made. A hole-punch
    /// camera reports a cutout a fraction of the notch's width, and a target
    /// that small at the top edge of the screen is one nobody hits.
    public static let minimumTargetWidth: CGFloat = 120
    /// The target on a Mac with no cutout at all.
    public static let noNotchTargetWidth: CGFloat = 130
    /// What the island draws in place of a notch on a Mac without one: a
    /// small black tab under the middle of the menu bar, the size the halo
    /// and the working light already traced. Without it they traced nothing
    /// — a smudge of light and a loose dash in the menu bar of a MacBook Neo
    /// or an external display.
    public static let virtualNotch = CGSize(width: 120, height: 24)

    /// The resting hover target's width for this machine.
    public var targetWidth: CGFloat { Self.targetWidth(for: size) }

    /// The same, from a cutout's size alone — what `IslandView` is handed.
    public static func targetWidth(for notch: CGSize) -> CGFloat {
        notch.width > 0 && notch.height > 0
            ? max(notch.width, minimumTargetWidth) : noNotchTargetWidth
    }

    /// Measure from what `NSScreen` reports: its `frame`,
    /// `safeAreaInsets.top`, `auxiliaryTopLeftArea` and
    /// `auxiliaryTopRightArea`.
    ///
    /// The two strips are taken in either coordinate space — the screen's own
    /// or the global one — by checking which of them the right-hand strip's
    /// edge agrees with. On the primary display the two are the same and
    /// nothing can tell them apart; on a laptop sitting to the right of an
    /// external monitor, reading them in the wrong space would put the island
    /// a whole screen away from its notch.
    public static func measure(frame: CGRect, safeAreaTop: CGFloat,
                               left: CGRect?, right: CGRect?) -> NotchGeometry {
        let height = max(safeAreaTop, 0)
        guard let left, let right, left.width > 0, right.width > 0 else {
            return NotchGeometry(size: CGSize(width: 0, height: height), centreX: frame.midX)
        }
        let local = abs(right.maxX - frame.maxX) > 1 && abs(right.maxX - frame.width) <= 1
        let origin = local ? frame.minX : 0
        let gapStart = origin + left.maxX
        let gapEnd = origin + right.minX
        let width = gapEnd - gapStart
        // A cutout wider than half the display is not a cutout; it is two
        // strips that were not describing one. Refuse it rather than draw it.
        guard width > 0, width < frame.width / 2 else {
            return NotchGeometry(size: CGSize(width: 0, height: height), centreX: frame.midX)
        }
        return NotchGeometry(size: CGSize(width: width, height: height),
                             centreX: (gapStart + gapEnd) / 2)
    }

    /// Which display the island lives on: the first with a notch, because
    /// that is where Moe lives; otherwise the first display, which is the one
    /// carrying the menu bar.
    ///
    /// Deliberately not "the screen under the cursor". The window is built
    /// once and never follows the pointer, so measuring the screen under it
    /// is what let the notch and the window disagree.
    public static func hostIndex(notched: [Bool]) -> Int {
        notched.firstIndex(of: true) ?? 0
    }
}
