import SwiftUI

/// The island's outline: exactly the notch's width where it meets the top of
/// the screen, flaring outward into the panel below.
///
/// A plain rounded rectangle is what makes these things look like a separate
/// box stuck under the notch. The concave shoulders here are the whole trick —
/// the shape leaves the notch at precisely the notch's width, so there is no
/// seam, and widens on a curve so it reads as the hardware growing rather than
/// a window appearing.
struct IslandShape: Shape {
    /// Width of the physical notch — the width of this shape's top edge.
    var topWidth: CGFloat
    /// Radius of the two bottom corners.
    var cornerRadius: CGFloat
    /// How far the concave shoulders travel before the sides go vertical.
    var shoulder: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var p = Path()

        let top = min(max(topWidth, 0), rect.width)
        let halfTop = top / 2
        let midX = rect.midX
        let r = min(cornerRadius, rect.height / 2)
        let sh = min(shoulder, max(rect.height - r, 0))

        // Top edge — the seam against the notch.
        p.move(to: CGPoint(x: midX - halfTop, y: rect.minY))

        // Left shoulder: curve outward and down to the full width.
        p.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + sh),
            control1: CGPoint(x: midX - halfTop - sh * 0.55, y: rect.minY),
            control2: CGPoint(x: rect.minX, y: rect.minY + sh * 0.45))

        // Left side down to the bottom-left corner.
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: rect.maxY))

        // Bottom edge.
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))

        // Right side back up.
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + sh))

        // Right shoulder: curve back in to the notch's edge.
        p.addCurve(
            to: CGPoint(x: midX + halfTop, y: rect.minY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + sh * 0.45),
            control2: CGPoint(x: midX + halfTop + sh * 0.55, y: rect.minY))

        p.closeSubpath()
        return p
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topWidth, cornerRadius) }
        set { topWidth = newValue.first; cornerRadius = newValue.second }
    }
}

/// The dropped panel: a slab hanging from the top edge of the screen, with
/// only its bottom corners rounded.
///
/// This replaces `IslandShape` for the panel itself. That shape's concave
/// shoulders were built to meet the notch's lower edge at exactly the notch's
/// width, so the two read as one object — but it still began *below* the
/// notch, which drew a horizontal seam across the menu bar and made the panel
/// look like a lid hanging off the hardware.
///
/// Covering the notch instead removes the seam entirely: the band over the
/// cutout is filled in the same true black as the bezel, so on a notched Mac
/// the notch disappears for as long as the panel is open, and on a Mac without
/// one nothing about the drawing has to change. The top corners are square
/// because they are against the edge of the display, where a radius would show
/// as two notches of desktop.
///
/// `IslandShape` is kept: the travelling trail still traces the notch outline
/// itself, which is a different shape from the panel around it.
struct IslandPanelShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }
}

/// A piece of the notch outline, positioned by how far around it has travelled.
///
/// `start` is a fraction of the way around the perimeter and may run past 1 or
/// below 0; it wraps. Because the animation moves the *trim* rather than
/// rotating the shape, the lit piece follows the outline — down the side,
/// across the bottom, around the corners — instead of sweeping around the
/// centre like a clock hand.
struct TrailSegment: Shape {
    var start: CGFloat
    var length: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let outline = Path(roundedRect: rect, cornerRadius: radius,
                           style: .continuous)
        var from = start.truncatingRemainder(dividingBy: 1)
        if from < 0 { from += 1 }
        let to = from + length

        var path = Path()
        if to <= 1 {
            path.addPath(outline.trimmedPath(from: from, to: to))
        } else {
            // Wrapping past the start point: draw the two halves.
            path.addPath(outline.trimmedPath(from: from, to: 1))
            path.addPath(outline.trimmedPath(from: 0, to: to - 1))
        }
        return path
    }

    var animatableData: CGFloat {
        get { start }
        set { start = newValue }
    }
}
