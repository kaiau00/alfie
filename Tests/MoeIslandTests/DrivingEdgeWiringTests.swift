import Foundation
import Testing

/// The magenta line around the screen while Moe drives (2026-09-24). Three
/// properties it must never lose, read off the source because the window is
/// AppKit: it cannot take a click (Moe is clicking under it), it is out of
/// screen captures (Moe reads screenshots while it drives, and must not see
/// its own frame), and it follows both kinds of driving — an app, and Moe's
/// own browser.
struct DrivingEdgeWiringTests {

    private static func read(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theEdgeNeverTakesAClickAndIsNotCaptured() throws {
        let edge = try #require(Self.read("Sources/Moe/DrivingEdge.swift"))
        #expect(edge.contains("w.ignoresMouseEvents = true"), "the edge would swallow the clicks Moe makes under it")
        #expect(edge.contains("w.sharingType = .none"), "the edge would appear in the screenshots Moe reads")
        #expect(edge.contains("conductor.$drivingApp") && edge.contains("conductor.$browsing"),
                "the edge does not follow both an app and Moe's own browser")
    }

    @Test func theAppStartsIt() throws {
        let app = try #require(Self.read("Sources/Moe/AppDelegate.swift"))
        #expect(app.contains("drivingEdge = DrivingEdge(conductor: conductor)"))
    }
}
