import AppKit
import SwiftUI

/// A strip the card can be dragged by.
///
/// `isMovableByWindowBackground` was meant to make the whole card draggable,
/// and did not: the recipient and the message are selectable text, and
/// selectable text takes the mouse-down for a selection — so on most of the
/// card a drag selected words, and on the rest there was nothing to grab
/// (the owner, 2026-09-25: the card "could not be moved"). The header has no
/// controls and nothing selectable, so it is the handle: laid OVER the header
/// rather than behind it, so nothing in the header can take the click first.
struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
