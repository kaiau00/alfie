import Foundation
import Testing

/// `beginTrace()` clears the turn's speech span. The engine read that span
/// to measure the turn *after* calling it, from 2026-09-06 to 2026-10-07,
/// so every turn in the follow-up window was weighed by its last VAD
/// segment and long requests were dropped as "not for Moe". The span must
/// be read first. Move the read back below the trace and this goes red.
struct TurnSpanWiringTests {

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theSpanIsReadBeforeTheTraceClearsIt() throws {
        let engine = try Self.source("Sources/Moe/Voice/VoiceEngine.swift")
        let transcribe = try #require(engine.range(of: "case .transcribe(let turn):"))
        let body = engine[transcribe.upperBound...]
        let read = try #require(body.range(of: "TurnAudio.speechSeconds("),
                                "the turn is no longer measured by TurnAudio.speechSeconds")
        let trace = try #require(body.range(of: "\n            beginTrace()\n"))
        #expect(read.lowerBound < trace.lowerBound,
                "the speech span is read after beginTrace() has cleared it")
        // And nothing in the turn reads the cleared span directly again.
        let afterTrace = body[trace.upperBound...]
        let caseEnd = afterTrace.range(of: "\n        case .")?.lowerBound ?? afterTrace.endIndex
        #expect(!afterTrace[..<caseEnd].contains("turnSpeechStartedAt"),
                "the turn reads turnSpeechStartedAt after beginTrace() cleared it")
    }
}
