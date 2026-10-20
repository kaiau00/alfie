import AppKit
import Foundation
import SwiftUI
import Testing
import MoeIsland
@testable import Moe

/// The folded island, drawn by the real `IslandView` and read pixel by pixel
/// (2026-10-15: "no more colors or glowing").
///
/// Two promises, both about what reaches the screen rather than about a
/// constant: nothing is drawn below the notch's band in any folded state —
/// the halo used to spill fifteen points and more down over the menu bar and
/// the window under it — and nothing drawn is coloured, except the one red
/// recording dot. Revert the redesign and both go red: the old halo was a
/// blurred green, white, amber, magenta or lavender lozenge under the notch.
@MainActor
struct IslandEarsRenderTests {

    static let notch = CGSize(width: 185, height: 32)
    static let canvas = CGSize(width: 700, height: 160)

    private func conductor(_ pose: (inout Conductor.SnapshotState) -> Void) throws -> Conductor {
        try StallGuardConductorTests.requireScratchHome()
        _ = NSApplication.shared
        var s = Conductor.SnapshotState()
        pose(&s)
        let c = Conductor(config: Config())
        c.pose(s)
        return c
    }

    private func view(_ c: Conductor, notch: CGSize = notch) -> IslandView {
        IslandView(conductor: c, presentation: .collapsed, notchSize: notch,
                   contentSize: CGSize(width: notch.width, height: 0),
                   draft: IslandDraft(), takesFocus: false,
                   onTap: {}, onHover: { _ in })
    }

    /// RGBA, premultiplied, row 0 at the top.
    private func pixels(_ v: IslandView) throws -> (data: [UInt8], width: Int, height: Int) {
        let r = ImageRenderer(content: v.frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .environment(\.islandSnapshot, true))
        r.scale = 1
        let cg = try #require(r.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (data, w, h)
    }

    private static let states: [(String, (inout Conductor.SnapshotState) -> Void)] = [
        ("idle", { _ in }),
        ("listening", { $0.mode = .listening; $0.inConversation = true; $0.level = 0.9 }),
        ("muted", { $0.mode = .listening; $0.inConversation = true; $0.micMuted = true; $0.level = 0.9 }),
        ("thinking", { $0.mode = .thinking; $0.working = true; $0.acting = true }),
        ("speaking", { $0.mode = .speaking; $0.inConversation = true }),
        ("paused", { $0.mode = .speaking; $0.inConversation = true; $0.replyPaused = true }),
        ("driving", { $0.mode = .thinking; $0.acting = true; $0.drivingApp = "Safari" }),
        ("dictation", { $0.dictation = .listening; $0.level = 0.8 }),
        ("transcribing", { $0.dictation = .transcribing }),
        ("notice", { s in
            s.notices = InboxSamples.items()
            s.noticePeek = s.notices.first
        }),
        ("waiting", { $0.notices = InboxSamples.items() }),
    ]

    @Test(arguments: [IslandEarsRenderTests.notch, .zero])
    func nothingIsDrawnBelowTheNotchInAnyState(notch: CGSize) throws {
        // The band the notch occupies, plus the running light's 2.5 pt inset
        // and its 2 pt stroke: that is all a folded island may cover.
        let band = Int((notch.height > 0 ? notch.height : NotchGeometry.virtualNotch.height) + 5)
        for (name, pose) in Self.states {
            let p = try pixels(view(try conductor(pose), notch: notch))
            var below = 0
            for y in band..<p.height {
                for x in 0..<p.width where p.data[(y * p.width + x) * 4 + 3] > 2 { below += 1 }
            }
            #expect(below == 0, "\(name): \(below) pixels drawn below the notch's band")
        }
    }

    @Test func everythingDrawnIsWhiteGreyOrBlack() throws {
        for (name, pose) in Self.states {
            let p = try pixels(view(try conductor(pose)))
            var coloured = 0
            for i in stride(from: 0, to: p.data.count, by: 4) where p.data[i + 3] > 12 {
                let rgb = [p.data[i], p.data[i + 1], p.data[i + 2]].map(Int.init)
                if rgb.max()! - rgb.min()! > 12 { coloured += 1 }
            }
            #expect(coloured == 0, "\(name): \(coloured) coloured pixels")
        }
    }

    /// The control: the one colour that stays — a recorded meeting's dot —
    /// is found by the same reading, so the check above can see colour.
    @Test func theRecordingDotIsTheOneColour() throws {
        let c = try conductor { $0.meeting = .recording(since: Date()) }
        #expect(view(c).ears.left == .recording(paused: false, whisper: false))
        let p = try pixels(view(c))
        var red = 0
        for i in stride(from: 0, to: p.data.count, by: 4) where p.data[i + 3] > 200 {
            if Int(p.data[i]) - Int(p.data[i + 1]) > 60 { red += 1 }
        }
        #expect(red > 4, "the recording dot should be red")
    }

    /// The notification pill: out while the notice peeks, gone with it.
    @Test func aNoticeRidesInTheRightEarAndLeavesWithIt() throws {
        let item = InboxSamples.items()[0]
        let c = try conductor { s in
            s.notices = [item]
            s.noticePeek = item
        }
        guard case .notice(let line)? = view(c).ears.right else {
            Issue.record("no notice in the right ear: \(String(describing: view(c).ears.right))")
            return
        }
        #expect(line == NoticeTab.earLine(item))
        let out = IslandView.earReach(view(c).ears).right

        let after = try conductor { $0.notices = [item] }
        let back = IslandView.earReach(view(after).ears).right
        #expect(view(after).ears.right == .waiting)
        #expect(out > back + 60, "the ear widens for the line (\(out)) and shrinks back (\(back))")

        // Drawn: the pill reaches well past the notch on the right, and the
        // left of the notch stays clear menu bar.
        let p = try pixels(view(c))
        let mid = p.width / 2
        let y = Int(Self.notch.height / 2)
        let rightEdge = (mid..<p.width).last { p.data[(y * p.width + $0) * 4 + 3] > 200 } ?? mid
        let leftEdge = (0..<mid).first { p.data[(y * p.width + $0) * 4 + 3] > 200 } ?? mid
        #expect(rightEdge - mid > Int(Self.notch.width / 2) + 60)
        #expect(mid - leftEdge <= Int(Self.notch.width / 2) - IslandEars.overlap.toInt + 1,
                "nothing out on the left: \(mid - leftEdge)")
    }
}

private extension CGFloat {
    var toInt: Int { Int(self) }
}
