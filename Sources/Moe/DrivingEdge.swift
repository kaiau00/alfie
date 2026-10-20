import AppKit
import Combine
import SwiftUI
import MoeDesign

/// A thin magenta line around the edge of every screen while Moe has the
/// mouse and keyboard (the owner's island review, 2026-09-24).
///
/// The only sign used to be the notch turning magenta — easy to miss while
/// you look at the middle of the screen, which is exactly where Moe is
/// clicking. This is the one light that reaches the edge of the display, and
/// it means one thing: Moe is driving. It never takes a click, never takes
/// focus, and is left out of screen captures (`sharingType = .none`), so the
/// screenshots Moe reads while it drives do not show its own frame.
@MainActor
final class DrivingEdge {
    private let conductor: Conductor
    private var windows: [NSWindow] = []
    private var observer: AnyCancellable?

    init(conductor: Conductor) {
        self.conductor = conductor
        observer = conductor.$drivingApp.map { $0 != nil }
            .combineLatest(conductor.$browsing)
            .map { $0 || $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] driving in self?.set(driving) }
    }

    private func set(_ driving: Bool) {
        if driving { show() } else { hide() }
    }

    private func show() {
        hide()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            // Out of every screenshot and recording, including Moe's own.
            w.sharingType = .none
            w.contentView = NSHostingView(rootView: EdgeLine())
            w.setFrame(screen.frame, display: false)
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; w.animator().alphaValue = 1 }
            windows.append(w)
        }
    }

    private func hide() {
        let going = windows
        windows = []
        for w in going {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; w.animator().alphaValue = 0 },
                                                 completionHandler: { w.orderOut(nil) })
        }
    }
}

/// The line itself: 2 pt of magenta at the very edge, a soft falloff inside
/// it, breathing slowly so it reads as live rather than as a bezel.
private struct EdgeLine: View {
    @State private var up = false

    var body: some View {
        ZStack {
            Rectangle()
                .strokeBorder(Theme.Island.driving.opacity(up ? 0.95 : 0.7), lineWidth: 2)
            Rectangle()
                .strokeBorder(Theme.Island.driving.opacity(up ? 0.35 : 0.2), lineWidth: 14)
                .blur(radius: 12)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { up = true }
        }
    }
}
