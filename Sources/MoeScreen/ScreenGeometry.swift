import CoreGraphics
import Foundation

/// Maps a pixel in a screenshot back to the point on screen it shows.
///
/// A capture is taken of one display (`displayFrame`, in global
/// CoreGraphics points, top-left origin — a secondary display left of the
/// primary has a negative `origin.x`) and downscaled to `width`×`height`
/// pixels, so one screenshot pixel is `1/scale` points. Pure arithmetic,
/// kept here so it can be unit-tested with concrete numbers.
public struct ScreenGeometry: Sendable {
    public let width: Int
    public let height: Int
    public let displayFrame: CGRect

    public init(width: Int, height: Int, displayFrame: CGRect) {
        self.width = width; self.height = height; self.displayFrame = displayFrame
    }

    /// Screenshot pixels per screen point (2 on a Retina display captured at
    /// full resolution; a little over 1 after the 1568-px downscale).
    public var scale: CGFloat { CGFloat(width) / max(displayFrame.width, 1) }

    /// True when `x,y` lies inside the screenshot (edges inclusive).
    public func contains(x: Int, y: Int) -> Bool {
        (0...width).contains(x) && (0...height).contains(y)
    }

    /// Screenshot pixel → CoreGraphics screen point (top-left origin), the
    /// coordinates `CGWarpMouseCursorPosition` and `SCDisplay.frame` use.
    public func screenPoint(x: Int, y: Int) -> CGPoint {
        CGPoint(x: displayFrame.origin.x + CGFloat(x) / scale,
                y: displayFrame.origin.y + CGFloat(y) / scale)
    }

    /// The same point in AppKit coordinates (bottom-left origin, y up),
    /// given the primary display's height — where an `NSWindow` goes.
    public func appKitPoint(x: Int, y: Int, primaryHeight: CGFloat) -> CGPoint {
        let cg = screenPoint(x: x, y: y)
        return CGPoint(x: cg.x, y: primaryHeight - cg.y)
    }
}
