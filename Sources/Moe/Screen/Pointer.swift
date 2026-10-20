import AppKit
import QuartzCore

/// The glowing ring Moe puts on the screen when it says "[POINT:…] this
/// one" — clicky's best trick. A transparent, click-through panel above
/// everything (screen-saver level, every Space) draws a pulsing ring with
/// a short label under it, then fades after a few seconds or when the next
/// tag arrives. It never takes focus and never takes a click.
///
/// Optionally the real cursor is moved there too (`CGWarpMouseCursorPosition`,
/// no click). Off by default: grabbing the mouse is intrusive.
@MainActor
final class PointerOverlay {

    static let lifetime: TimeInterval = 4
    private static let ringSize: CGFloat = 44
    private static let panelSize = NSSize(width: 320, height: 120)

    private var panel: NSPanel?
    private var view: RingView?
    private var hideWork: DispatchWorkItem?

    init() {}

    /// Show the ring at a CoreGraphics-coordinate point (top-left origin).
    func point(at cg: CGPoint, label: String, moveMouse: Bool) {
        let panel = panel ?? makePanel()
        let view = view!

        // CG → AppKit: flip through the primary display's height.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ak = NSPoint(x: cg.x, y: primaryHeight - cg.y)
        let size = Self.panelSize
        // Ring centred on the point; the label hangs below it.
        panel.setFrame(NSRect(x: ak.x - size.width / 2, y: ak.y - size.height + Self.ringSize / 2 + 24,
                              width: size.width, height: size.height), display: false)
        view.label = label
        view.needsDisplay = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        view.pulse()

        if moveMouse { CGWarpMouseCursorPosition(cg) }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fade() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime, execute: work)
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        panel?.orderOut(nil)
    }

    private func fade() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.panel?.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = RingView(frame: NSRect(origin: .zero, size: Self.panelSize), ringSize: Self.ringSize)
        p.contentView = v
        panel = p
        view = v
        return p
    }

    /// A ring with a soft glow and a label pill beneath it.
    private final class RingView: NSView {
        var label = ""
        private let ringSize: CGFloat
        private let ring = CAShapeLayer()
        private let glow = CAShapeLayer()

        init(frame: NSRect, ringSize: CGFloat) {
            self.ringSize = ringSize
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            let center = CGPoint(x: frame.midX, y: frame.height - ringSize / 2 - 24)
            let rect = CGRect(x: center.x - ringSize / 2, y: center.y - ringSize / 2, width: ringSize, height: ringSize)
            for (l, width, alpha) in [(glow, CGFloat(10), CGFloat(0.35)), (ring, CGFloat(3.5), CGFloat(1))] {
                l.path = CGPath(ellipseIn: rect, transform: nil)
                l.fillColor = NSColor.clear.cgColor
                l.strokeColor = NSColor(calibratedRed: 0.25, green: 0.55, blue: 1, alpha: alpha).cgColor
                l.lineWidth = width
                layer?.addSublayer(l)
            }
            glow.shadowColor = NSColor(calibratedRed: 0.25, green: 0.55, blue: 1, alpha: 1).cgColor
            glow.shadowOpacity = 0.9
            glow.shadowRadius = 12
            glow.shadowOffset = .zero
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { false }

        func pulse() {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 1.6; a.toValue = 1
            a.duration = 0.45
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let b = CABasicAnimation(keyPath: "opacity")
            b.fromValue = 0; b.toValue = 1
            b.duration = 0.25
            for l in [ring, glow] {
                let c = CGRect(x: bounds.midX, y: bounds.height - ringSize / 2 - 24, width: 0, height: 0)
                l.bounds = bounds
                l.position = CGPoint(x: bounds.midX, y: bounds.midY)
                l.anchorPoint = CGPoint(x: c.midX / bounds.width, y: c.midY / bounds.height)
                l.position = CGPoint(x: c.midX, y: c.midY)
                l.add(a, forKey: "pulse")
                l.add(b, forKey: "in")
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard !label.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let text = NSAttributedString(string: label, attributes: attrs)
            var size = text.size()
            size.width = min(size.width, bounds.width - 24)
            let pad: CGFloat = 8
            let pill = NSRect(x: bounds.midX - size.width / 2 - pad,
                              y: bounds.height - ringSize - 24 - 10 - size.height - pad,
                              width: size.width + pad * 2, height: size.height + pad)
            let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.9, alpha: 0.92).setFill()
            path.fill()
            text.draw(in: NSRect(x: pill.minX + pad, y: pill.minY + pad / 2, width: size.width, height: size.height))
        }
    }
}
