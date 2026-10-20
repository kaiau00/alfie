import Testing
import CoreGraphics
import Foundation
@testable import MoeScreen

@Suite struct ScreenGeometryTests {

    /// 14" MacBook Pro: 1512×982 pt at 2×, captured 3024×1964 px and
    /// downscaled so the long side is 1568.
    @Test func retinaPrimaryDownscaled() {
        let g = ScreenGeometry(width: 1568, height: 1018, displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(abs(g.scale - 1568.0 / 1512.0) < 1e-9)
        let p = g.screenPoint(x: 784, y: 509)
        #expect(abs(p.x - 756) < 0.01)
        #expect(abs(p.y - 490.9) < 0.1)
        #expect(g.screenPoint(x: 0, y: 0) == CGPoint(x: 0, y: 0))
        #expect(abs(g.screenPoint(x: 1568, y: 1018).x - 1512) < 0.01)
    }

    /// Full-resolution 2× capture, no downscale: scale is exactly 2.
    @Test func retinaFullResolution() {
        let g = ScreenGeometry(width: 2880, height: 1800, displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(g.scale == 2)
        #expect(g.screenPoint(x: 100, y: 50) == CGPoint(x: 50, y: 25))
    }

    /// External 1× display to the right of and above the primary, i.e.
    /// not the main display and with a y origin above the primary's top.
    @Test func secondaryDisplayRightOfPrimary() {
        let g = ScreenGeometry(width: 1568, height: 882, displayFrame: CGRect(x: 1512, y: -300, width: 2560, height: 1440))
        let p = g.screenPoint(x: 0, y: 0)
        #expect(p == CGPoint(x: 1512, y: -300))
        let c = g.screenPoint(x: 784, y: 441)
        #expect(abs(c.x - (1512 + 1280)) < 0.01)
        #expect(abs(c.y - (-300 + 720)) < 0.01)
    }

    /// Secondary display left of the primary: negative x origin.
    @Test func secondaryDisplayNegativeOrigin() {
        let g = ScreenGeometry(width: 1568, height: 882, displayFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
        #expect(g.screenPoint(x: 0, y: 0) == CGPoint(x: -2560, y: 0))
        let far = g.screenPoint(x: 1568, y: 882)
        #expect(abs(far.x - 0) < 0.01)
        #expect(abs(far.y - 1440) < 0.01)
    }

    /// AppKit flip: CG y 100 on a 982-pt primary is AppKit y 882.
    @Test func appKitFlip() {
        let g = ScreenGeometry(width: 1512, height: 982, displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(g.appKitPoint(x: 10, y: 100, primaryHeight: 982) == CGPoint(x: 10, y: 882))
        // Secondary display below the primary (CG y > primary height) lands
        // at a negative AppKit y, as AppKit expects.
        let below = ScreenGeometry(width: 1920, height: 1080, displayFrame: CGRect(x: 0, y: 982, width: 1920, height: 1080))
        #expect(below.appKitPoint(x: 0, y: 0, primaryHeight: 982) == CGPoint(x: 0, y: 0))
        #expect(below.appKitPoint(x: 0, y: 1080, primaryHeight: 982) == CGPoint(x: 0, y: -1080))
    }

    @Test func boundsAreInclusive() {
        let g = ScreenGeometry(width: 100, height: 50, displayFrame: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(g.contains(x: 0, y: 0))
        #expect(g.contains(x: 100, y: 50))
        #expect(!g.contains(x: 101, y: 0))
        #expect(!g.contains(x: -1, y: 0))
        #expect(!g.contains(x: 0, y: 51))
    }

    @Test func zeroWidthFrameDoesNotDivideByZero() {
        let g = ScreenGeometry(width: 10, height: 10, displayFrame: .zero)
        #expect(g.scale == 10)
        #expect(g.screenPoint(x: 10, y: 10) == CGPoint(x: 1, y: 1))
    }
}
