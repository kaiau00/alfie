import Foundation
import Testing
@testable import MoeVoice

/// Item 5 of the 2026-09-22 voice audit: what a future noise dataset needs.
/// A barge-in the machine refused used to leave no trace row at all, the
/// stall net was logged as "turn-model", and no VAD probability was kept.
struct VoiceDebugTests {

    // MARK: Rows for refused onsets

    @Test func aSoundLetGoWithNoWordsSaysSo() {
        var m = VoiceMachine()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "what time is it"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        let out = m.handle(.timer(.bargeInHold))
        #expect(out.contains(.onsetRejected(.noWords)))
    }

    @Test func wordsJudgedNotThePersonsSaySo() {
        var m = VoiceMachine()
        m.tuning.conversation = true
        m.tuning.bargeIn = true
        _ = m.handle(.toggle); _ = m.handle(.speechStarted); _ = m.handle(.endOfUtterance("…"))
        guard case .deciding(_, let turn) = m.state else { Issue.record("\(m.state)"); return }
        _ = m.handle(.transcribed(turn: turn, "what time is it"))
        _ = m.handle(.speechQueued)
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(2))
        #expect(m.handle(.bargeInJudged(false)).contains(.onsetRejected(.notForMoe)))
        // A barge-in that was taken is not a rejection.
        _ = m.handle(.speechStarted)
        _ = m.handle(.wordsHeard(2))
        #expect(!m.handle(.bargeInJudged(true)).contains { if case .onsetRejected = $0 { return true }; return false })
    }

    // MARK: Trace

    @Test func theTraceCarriesTheNewNumbers() throws {
        var t = TurnTrace(source: "onset", startedAt: Date(timeIntervalSince1970: 0))
        t.endpoint = "stall"
        t.vadMeanP = 0.912
        t.turnModelP = [0.12, 0.81]
        t.onsetWindow = "speaking"
        t.onsetWords = 0
        let line = try #require(t.jsonLine())
        let back = try JSONDecoder.iso.decode(TurnTrace.self, from: Data(line.utf8))
        #expect(back == t)
        #expect(line.contains("\"endpoint\":\"stall\""))
        // Numbers, never words: nothing in the row can hold a transcript.
        #expect(!line.contains("text"))
    }

    @Test func vadStatsAverageAndPeak() {
        var s = VoiceDebug.VadStats()
        #expect(s.mean == nil)
        s.add(0.2); s.add(0.9); s.add(.nan)
        #expect(s.count == 2)
        #expect(abs((s.mean ?? 0) - 0.55) < 1e-6)
        #expect(abs(s.max - 0.9) < 1e-6)
    }

    // MARK: Clips

    @Test func aClipIsAPlayableWav() {
        let data = VoiceDebug.wav([0, 0.5, -0.5, 2], sampleRate: 16_000)
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        // Clipped, not wrapped: 2.0 is full scale.
        let last = data.suffix(2)
        #expect(Int16(bitPattern: UInt16(last.first!) | UInt16(last.last!) << 8) == 32767)
    }

    @Test func namesSortByTimeAndSayWhy() {
        let a = VoiceDebug.fileName(at: Date(timeIntervalSince1970: 1_000), reason: "rejected-no-words")
        let b = VoiceDebug.fileName(at: Date(timeIntervalSince1970: 2_000), reason: "end stall")
        #expect(a < b)
        #expect(a.hasSuffix("-rejected-no-words.wav"))
        #expect(b.hasSuffix("-end-stall.wav"))
    }

    @Test func theOldestGoFirstToStayUnderTheCap() {
        let stored = [VoiceDebug.Stored(name: "3.wav", bytes: 40),
                      VoiceDebug.Stored(name: "1.wav", bytes: 40),
                      VoiceDebug.Stored(name: "2.wav", bytes: 40)]
        #expect(VoiceDebug.prune(stored, incoming: 10, cap: 200).isEmpty)
        #expect(VoiceDebug.prune(stored, incoming: 50, cap: 150) == ["1.wav"])
        #expect(VoiceDebug.prune(stored, incoming: 100, cap: 150) == ["1.wav", "2.wav"])
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
