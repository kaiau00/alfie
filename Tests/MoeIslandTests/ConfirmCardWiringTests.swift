import Foundation
import Testing

/// The send card (`moe-confirm`), 2026-09-25, the owner: pasting into the
/// subject did nothing, and the card stayed on the desktop it arrived on.
/// Read off the source, because the card is its own AppKit process.
struct ConfirmCardWiringTests {

    private static var main: String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent("Sources/MoeConfirm/main.swift"),
                           encoding: .utf8)
    }

    /// An accessory app has no menu bar, so ⌘V had no Edit menu to match.
    @Test func pasteReachesTheFields() throws {
        let src = try #require(Self.main)
        #expect(src.contains("application.mainMenu = mainMenu"))
        #expect(src.contains(#"#selector(NSText.paste(_:)), keyEquivalent: "v""#))
        // Nothing in that menu may answer the card.
        #expect(!src.contains("terminate(_:)), keyEquivalent"))
    }

    /// On every Space, not only the one it arrived on.
    @Test func theCardFollowsYouToEveryDesktop() throws {
        let src = try #require(Self.main)
        #expect(src.contains("window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]"))
        #expect(!src.contains("window.collectionBehavior = [.moveToActiveSpace"))
    }

    private static func source(_ name: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent("Sources/MoeConfirm/\(name)"),
                           encoding: .utf8)
    }

    /// 2026-09-25, the owner: "Cancel did nothing." The half-second guard
    /// held Cancel too, and a .plain pill hit-tested only its hairline.
    @Test func cancelIsNeverHeldAndTheWholePillTakesTheClick() throws {
        let src = try #require(Self.main)
        #expect(src.contains("onCancel: { exit(CONFIRM_CANCELLED) },"))
        #expect(!src.contains("onCancel: { if Approval.ready"))
        // Send is still held.
        #expect(src.contains("guard Approval.ready else { return }"))
        let sheet = try #require(Self.source("ConfirmSheet.swift"))
        let cancel = try #require(sheet.range(of: "Button(action: onCancel)"))
        let shortcut = try #require(sheet.range(of: ".keyboardShortcut(.cancelAction)"))
        #expect(sheet[cancel.upperBound..<shortcut.lowerBound].contains(".contentShape("))
    }

    /// The first click on a card that is not in front is an answer, not
    /// just an activation.
    @Test func theFirstClickIsTaken() throws {
        let src = try #require(Self.main)
        #expect(src.contains("override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }"))
        #expect(src.contains("let hosting = FirstClickHostingView(rootView: sheet)"))
    }

    /// "It could not be moved": the header is a real drag handle, laid over
    /// it so selectable text cannot take the mouse-down first.
    @Test func theCardCanBeDraggedByItsHeader() throws {
        let sheet = try #require(Self.source("ConfirmSheet.swift"))
        #expect(sheet.contains(".overlay(WindowDragStrip())"))
        let drag = try #require(Self.source("WindowDrag.swift"))
        #expect(drag.contains("window?.performDrag(with: event)"))
    }

    /// "It blocked the chat": floating when it arrives, normal once the
    /// person has looked away — still on every Space (theCardFollowsYou…).
    @Test func itStopsFloatingOnceThePersonLooksAway() throws {
        let src = try #require(Self.main)
        #expect(src.contains("forName: NSWindow.didResignKeyNotification"))
        #expect(src.contains("window.level = .normal"))
        #expect(src.contains("ConfirmPlacement.origin(card:"))
    }

    /// Bound to its requester before anything is drawn.
    @Test func theLifecycleStartsBeforeTheWindow() throws {
        let src = try #require(Self.main)
        let start = try #require(src.range(of: "\nstartLifecycle()\n"))
        let window = try #require(src.range(of: "let window = ConfirmWindow("))
        #expect(start.lowerBound < window.lowerBound)
        #expect(src.contains("exit(CONFIRM_WITHDRAWN)"))
    }
}
