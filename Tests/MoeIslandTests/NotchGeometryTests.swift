import CoreGraphics
import Testing
@testable import MoeIsland

/// Every Mac the island has to sit on, as `NSScreen` describes it.
///
/// The first case is measured, not recalled: a 13-inch MacBook Air (Mac15,12)
/// on 2026-09-14 reported a 1470 × 956 pt frame, a 32 pt safe area, and menu
/// bar strips of 646 pt at x 0 and 645 pt at x 825. The Pros are published
/// figures laid out the same way. Every Mac without a notch — the MacBook Neo,
/// the M1 Air, an iMac, any external display — reports no strips and no inset.
struct NotchGeometryTests {

    private static let airFrame = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private static let airLeft = CGRect(x: 0, y: 924, width: 646, height: 32)
    private static let airRight = CGRect(x: 825, y: 924, width: 645, height: 32)

    @Test func theThirteenInchAirAsMeasured() {
        let g = NotchGeometry.measure(frame: Self.airFrame, safeAreaTop: 32,
                                      left: Self.airLeft, right: Self.airRight)
        #expect(g.size == CGSize(width: 179, height: 32))
        #expect(g.hasNotch)
        // Half a point right of the screen's centre, which is 735. Centring
        // the window on the screen is what left a hairline of bezel showing.
        #expect(g.centreX == 735.5)
        #expect(g.centreX != Self.airFrame.midX)
    }

    @Test func theFourteenInchPro() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let g = NotchGeometry.measure(frame: frame, safeAreaTop: 32,
                                      left: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                      right: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
        #expect(g.size == CGSize(width: 185, height: 32))
        #expect(g.centreX == 756)
    }

    @Test func theSixteenInchProAtMoreSpace() {
        let frame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let g = NotchGeometry.measure(frame: frame, safeAreaTop: 38,
                                      left: CGRect(x: 0, y: 1131, width: 790, height: 38),
                                      right: CGRect(x: 1010, y: 1131, width: 790, height: 38))
        #expect(g.size == CGSize(width: 220, height: 38))
        #expect(g.centreX == 900)
    }

    /// The MacBook Neo, the M1 Air, an iMac, an external display.
    @Test func aMacWithNoNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1504, height: 941)
        let g = NotchGeometry.measure(frame: frame, safeAreaTop: 0, left: nil, right: nil)
        #expect(!g.hasNotch)
        #expect(g.size == .zero)
        #expect(g.centreX == frame.midX)
        #expect(g.targetWidth == NotchGeometry.noNotchTargetWidth)
    }

    /// The laptop to the right of a 1920 pt external monitor. Whichever space
    /// the strips come in, the notch is where the laptop is — not 1920 pt to
    /// the left of it, on somebody's spreadsheet.
    @Test func aLaptopBesideAnExternalDisplay() {
        let frame = CGRect(x: 1920, y: 0, width: 1470, height: 956)
        let global = NotchGeometry.measure(
            frame: frame, safeAreaTop: 32,
            left: Self.airLeft.offsetBy(dx: 1920, dy: 0),
            right: Self.airRight.offsetBy(dx: 1920, dy: 0))
        let local = NotchGeometry.measure(frame: frame, safeAreaTop: 32,
                                          left: Self.airLeft, right: Self.airRight)
        #expect(global.centreX == 1920 + 735.5)
        #expect(local == global)
    }

    @Test func aLaptopToTheLeftOfItsMainDisplay() {
        let frame = CGRect(x: -1470, y: 0, width: 1470, height: 956)
        let global = NotchGeometry.measure(
            frame: frame, safeAreaTop: 32,
            left: Self.airLeft.offsetBy(dx: -1470, dy: 0),
            right: Self.airRight.offsetBy(dx: -1470, dy: 0))
        let local = NotchGeometry.measure(frame: frame, safeAreaTop: 32,
                                          left: Self.airLeft, right: Self.airRight)
        #expect(global.centreX == -1470 + 735.5)
        #expect(local == global)
        #expect(global.size.width == 179)
    }

    /// A camera hole a fraction of a notch's width still gets a target a
    /// person can hit with a pointer.
    @Test func aHolePunchCameraStillGetsAHittableTarget() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let g = NotchGeometry.measure(frame: frame, safeAreaTop: 32,
                                      left: CGRect(x: 0, y: 950, width: 736, height: 32),
                                      right: CGRect(x: 776, y: 950, width: 736, height: 32))
        #expect(g.size.width == 40)
        #expect(g.targetWidth == NotchGeometry.minimumTargetWidth)
        #expect(NotchGeometry.targetWidth(for: CGSize(width: 179, height: 32)) == 179)
    }

    /// Strips that overlap, or leave most of the screen between them, are not
    /// describing a notch. No notch is the honest reading.
    @Test func stripsThatDescribeNoCutoutAreRefused() {
        let overlapping = NotchGeometry.measure(
            frame: Self.airFrame, safeAreaTop: 32,
            left: CGRect(x: 0, y: 924, width: 900, height: 32), right: Self.airRight)
        #expect(!overlapping.hasNotch)
        let vast = NotchGeometry.measure(
            frame: Self.airFrame, safeAreaTop: 32,
            left: CGRect(x: 0, y: 924, width: 100, height: 32),
            right: CGRect(x: 1370, y: 924, width: 100, height: 32))
        #expect(!vast.hasNotch)
        #expect(vast.centreX == Self.airFrame.midX)
    }

    /// An inset with no strips: no notch to draw, but the height is kept so
    /// the panel's content still starts below whatever the inset is for.
    @Test func anInsetWithoutStripsKeepsItsHeight() {
        let g = NotchGeometry.measure(frame: Self.airFrame, safeAreaTop: 32, left: nil, right: nil)
        #expect(!g.hasNotch)
        #expect(g.size.height == 32)
    }

    @Test func theIslandLivesOnTheNotchedDisplay() {
        // External monitor first (it has the menu bar), laptop second.
        #expect(NotchGeometry.hostIndex(notched: [false, true]) == 1)
        #expect(NotchGeometry.hostIndex(notched: [true, false]) == 0)
        // No notch anywhere: the display with the menu bar.
        #expect(NotchGeometry.hostIndex(notched: [false, false]) == 0)
        #expect(NotchGeometry.hostIndex(notched: []) == 0)
    }
}
