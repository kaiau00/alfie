import AppKit
import Foundation
import Testing
@testable import Moe

/// The chime must never be able to take the app down. Twice on 2026-09-19 an
/// answer that finished during a lid close chimed on wake through an
/// `AVAudioPlayerNode` whose engine had no device cycles yet, and the
/// uncatchable exception aborted Moe. It plays files with `NSSound` now.
struct ChimeTests {

    @Test("the four tones are rendered to files at init, readable and short")
    @MainActor
    func renders() throws {
        let chime = Chime()
        for kind in [Chime.Kind.start, .stop, .cancel, .reply] {
            let url = try #require(chime.fileForTests(kind))
            let bytes = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            #expect(bytes > 4_000 && bytes < 100_000, "\(kind): \(bytes) bytes")
            #expect(NSSound(contentsOf: url, byReference: true) != nil)
        }
    }

    @Test("play never throws — with or without an output device it returns")
    @MainActor
    func playIsSafe() {
        let chime = Chime()
        chime.play(.reply)      // returns whatever the device does; the point is that it returns
        chime.play(.start)
        chime.play(.cancel)
    }

    @Test("no AVAudioEngine is left in this class")
    func noEngine() throws {
        let here = URL(fileURLWithPath: #filePath)
        let src = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Moe/Dictation/Chime.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        #expect(!text.contains("AVAudioPlayerNode()"))
        #expect(!text.contains("AVAudioEngine()"))
    }
}
