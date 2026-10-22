import CoreGraphics
import Foundation

/// Where a confirmation card goes on the screen: somewhere it can be read,
/// and not on top of the conversation it is about.
///
/// The card used to be centred, and Memoe's chat is centred too — so the
/// card sat squarely over the chat, above every window, on every desktop,
/// and a person who wanted to read what Moe had said about it could not
/// (the owner, 2026-09-25: "it blocked the chat"). The card still arrives
/// where it will be seen; it just steps out of the way of Memoe's own
/// windows when there is room to.
public enum ConfirmPlacement {
    /// Gap kept between the card and anything it steps around.
    public static let margin: CGFloat = 16

    /// The card's origin (Cocoa coordinates, bottom-left) inside `visible`.
    ///
    /// Centred when nothing is in the way. Otherwise the first of: below
    /// what it would cover, to its right, to its left, above it — whichever
    /// fits on the screen whole and clear. When none does, each of those is
    /// pulled back onto the screen and the one covering the least is used:
    /// the card is never placed partly off screen, because its buttons are
    /// the part that would go missing.
    public static func origin(card: CGSize, visible: CGRect, avoid: [CGRect]) -> CGPoint {
        let centred = CGPoint(x: visible.midX - card.width / 2, y: visible.midY - card.height / 2)
        let frame = CGRect(origin: centred, size: card)
        let blocking = avoid.filter { $0.intersects(frame) && $0.width > 1 && $0.height > 1 }
        guard !blocking.isEmpty else { return clamp(centred, card: card, into: visible) }
        let region = blocking.dropFirst().reduce(blocking[0]) { $0.union($1) }
        let candidates = [
            // below (Cocoa y grows upward)
            CGPoint(x: centred.x, y: region.minY - margin - card.height),
            // right
            CGPoint(x: region.maxX + margin, y: centred.y),
            // left
            CGPoint(x: region.minX - margin - card.width, y: centred.y),
            // above
            CGPoint(x: centred.x, y: region.maxY + margin),
        ]
        for point in candidates {
            let placed = CGRect(origin: point, size: card)
            if visible.contains(placed), !avoid.contains(where: { $0.intersects(placed) }) {
                return point
            }
        }
        var best = clamp(centred, card: card, into: visible)
        var bestCover = covered(CGRect(origin: best, size: card), by: avoid)
        for point in candidates {
            let pulled = clamp(point, card: card, into: visible)
            let cover = covered(CGRect(origin: pulled, size: card), by: avoid)
            if cover < bestCover { best = pulled; bestCover = cover }
        }
        return best
    }

    static func covered(_ rect: CGRect, by avoid: [CGRect]) -> CGFloat {
        avoid.reduce(0) { total, other in
            let overlap = rect.intersection(other)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
    }

    static func clamp(_ point: CGPoint, card: CGSize, into visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, visible.minX), max(visible.minX, visible.maxX - card.width)),
                y: min(max(point.y, visible.minY), max(visible.minY, visible.maxY - card.height)))
    }

    /// A window-server rectangle (top-left origin, y down, measured from the
    /// top of the primary display) in Cocoa's coordinates.
    public static func cocoaRect(fromWindowServer rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Alfie's own windows are the ones to keep clear of: the app
    /// and its workbench build.
    public static let appNames: Set<String> = ["Alfie", "Alfie Dev"]
}
