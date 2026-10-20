import Foundation
import Testing
@testable import Moe

/// Settings › Background › Noticed reads the two files the situations engine
/// writes (moe-home/lib/situations.py). The lines are that module's shapes.
struct NoticedReportTests {
    static let now = ISO8601DateFormatter().date(from: "2026-09-24T20:00:00Z")!

    @Test("the last day's decisions are counted, and older ones are not")
    func counts() {
        let monitor = """
        {"event": "gated", "why": ["not addressed to the owner"], "at": "2026-09-24T19:00:00Z"}
        {"event": "gated", "why": ["no signal"], "at": "2026-09-24T19:01:00Z"}
        {"event": "asked", "verdict": "no situation", "at": "2026-09-24T19:02:00Z"}
        {"event": "situation", "id": "sit_1", "at": "2026-09-24T19:03:00Z"}
        {"event": "read-failed", "at": "2026-09-24T19:04:00Z"}
        {"event": "gated", "why": ["no signal"], "at": "2026-09-22T19:00:00Z"}
        {"event": "tick", "at": "2026-09-24T19:05:00Z"}
        not json
        """
        let r = NoticedReport.parse(situations: nil, monitor: Data(monitor.utf8), now: Self.now)
        #expect(r.today.threads == 4)
        #expect(r.today.gated == 2)
        #expect(r.today.asked == 2)
        #expect(r.today.found == 1)
        #expect(r.today.failures == 1)
        #expect(r.today.reasons["no signal"] == 1)
        #expect(r.lastTick != nil)
    }

    @Test("open situations come first, newest first; settled ones last")
    func order() {
        let sits = """
        {"sit_a": {"title": "Old open", "status": "sensed", "updated_at": "2026-09-24T10:00:00Z", "p_wanted": 0.5,
                   "evidence": [{"id": "x", "quote": "pay by Friday"}],
                   "prepared": {"offer": "Ready to reply", "options": ["Pay half"], "draft": "Hi —",
                                "research": [{"point": "Usual practice", "source": "https://x.example/a"}]}},
         "sit_b": {"title": "Settled", "status": "resolved", "updated_at": "2026-09-24T19:00:00Z"},
         "sit_c": {"title": "New open", "status": "sensed", "updated_at": "2026-09-24T18:00:00Z", "next_move": "owner"}}
        """
        let r = NoticedReport.parse(situations: Data(sits.utf8), monitor: nil, now: Self.now)
        #expect(r.situations.map(\.title) == ["New open", "Old open", "Settled"])
        #expect(r.situations[1].quotes == ["pay by Friday"])
        #expect(r.situations[0].nextMove == "owner")
        #expect(r.situations[1].offer == "Ready to reply")
        #expect(r.situations[1].options == ["Pay half"])
        #expect(r.situations[1].draft == "Hi —")
        #expect(r.situations[1].research.first?.source == "https://x.example/a")
    }

    /// Review 2026-09-24 §20.
    @Test("a failed prepare counts as a failure, a declined one does not; a dismissed one sorts with the settled")
    func preparesAndDismissed() {
        let monitor = """
        {"event": "prepare-failed", "why": "TimeoutError: slow", "at": "2026-09-24T19:00:00Z"}
        {"event": "prepare-failed", "why": "nothing usable prepared", "at": "2026-09-24T19:01:00Z"}
        {"event": "dropped", "why": "the question failed 3 times", "at": "2026-09-24T19:02:00Z"}
        """
        let r = NoticedReport.parse(situations: nil, monitor: Data(monitor.utf8), now: Self.now)
        #expect(r.today.failures == 2)
        let sits = """
        {"sit_a": {"title": "Waved away", "status": "dismissed", "updated_at": "2026-09-24T19:00:00Z"},
         "sit_b": {"title": "Open", "status": "prepared", "updated_at": "2026-09-24T10:00:00Z"}}
        """
        let s = NoticedReport.parse(situations: Data(sits.utf8), monitor: nil, now: Self.now)
        #expect(s.situations.map(\.title) == ["Open", "Waved away"])
        #expect(s.situations[1].isSettled && !s.situations[0].isSettled)
    }

    @Test("two reports that differ only in research, stakes or quotes are not equal")
    func equality() {
        func one(_ extra: String) -> NoticedReport.Situation {
            let sits = """
            {"sit_a": {"title": "T", "status": "sensed", "updated_at": "2026-09-24T10:00:00Z" \(extra)}}
            """
            return NoticedReport.parse(situations: Data(sits.utf8), monitor: nil, now: Self.now).situations[0]
        }
        let base = one("")
        #expect(base != one(#", "at_stake": "$4,200""#))
        #expect(base != one(#", "evidence": [{"id": "m1", "quote": "pay by Friday"}]"#))
        #expect(base != one(#", "prepared": {"research": [{"point": "p", "source": "https://x.example"}]}"#))
        #expect(base != one(#", "p_wanted": 0.9"#))
    }

    @Test("only the monitor's tail is read, from a whole line")
    func tailOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noticed-tail-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = #"{"event": "gated", "why": ["no signal"], "at": "2026-09-24T19:00:00Z"}"# + "\n"
        try String(repeating: line, count: 2000).write(to: url, atomically: true, encoding: .utf8)
        let data = try #require(NoticedReport.tail(of: url, bytes: 10_000))
        #expect(data.count <= 10_000)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\"event\""))
    }

    @Test("promises: open first by date, no date last, then the settled; junk skipped")
    func promises() {
        let json = #"""
        {"prm_a": {"by": "owner", "who": "Dana", "what": "send the deck", "due": "2026-10-03", "status": "open",
                   "source": "native/whatsapp", "thread_name": "Dana", "evidence": [{"id": "i1", "quote": "I'll send it"}],
                   "updated_at": "2026-09-24T19:00:00Z"},
         "prm_b": {"by": "other", "who": "Acme", "what": "credit the order", "due": "", "status": "open"},
         "prm_c": {"by": "other", "who": "Yossi", "what": "pay back", "due": "2026-10-01T15:00", "status": "open"},
         "prm_d": {"by": "owner", "what": "call", "status": "kept", "updated_at": "2026-09-24T18:00:00Z"},
         "prm_e": {"by": "owner", "status": "open"},
         "prm_f": 5}
        """#
        let ps = NoticedReport.parsePromises(Data(json.utf8))
        #expect(ps.map(\.id) == ["prm_c", "prm_a", "prm_b", "prm_d"])
        #expect(ps[1].mine && !ps[0].mine)
        #expect(ps[1].quote == "I'll send it")
        #expect(!ps[3].isOpen)
        #expect(NoticedReport.parsePromises(nil).isEmpty)
        #expect(NoticedTab.dueWord("2026-10-01") == "Oct 1")
        #expect(NoticedTab.dueWord("2026-10-01T15:00") == "Oct 1, 15:00")
        #expect(NoticedTab.dueWord("soon") == "soon")
        #expect(NoticedTab.sourceName("moe/chats") == "your chats with Moe")
        #expect(NoticedTab.sourceName("native/call-recordings") == "recorded calls")
    }
}
