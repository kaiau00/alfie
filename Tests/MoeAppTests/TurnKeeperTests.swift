import Foundation
import Testing
@testable import Moe

/// docs/AWAY-HANDOFF.md slice 1 — the turn Moe is working on is kept, and a
/// stream a sleep broke is re-issued once. The end-to-end half is
/// scripts/test-turn-keeper.sh (built binary, fake Hermes, a real socket
/// reset); this is the rule and the record on their own.
struct TurnKeeperTests {

    static func record(resumed: Int = 0, age: TimeInterval = 0) -> TurnKeeper.Record {
        .init(text: "find me a cheap backpack", logAs: "find me a cheap backpack",
              startedAt: Date().addingTimeInterval(-age), sessionID: "s1", resumed: resumed)
    }

    @Test("a sleep-shaped break after a sleep is resumed once, with the note in front of the ask")
    func resumedOnce() {
        let v = TurnKeeper.verdict(for: Self.record(), error: .networkConnectionLost, slept: true)
        guard case .resume(let text) = v else { Issue.record("gave up"); return }
        #expect(text.hasPrefix(TurnKeeper.resumeNote))
        #expect(text.hasSuffix("find me a cheap backpack"))
        #expect(TurnKeeper.verdict(for: Self.record(resumed: 1), error: .networkConnectionLost, slept: true) == .giveUp)
    }

    @Test("a turn that had already sent or paid stops instead of going again, and says so")
    func consequentialStops() {
        #expect(TurnKeeper.verdict(for: Self.record(), error: .networkConnectionLost, slept: true,
                                   consequential: true) == .stop)
        // Without a sleep it is still the ordinary failure, not a stop.
        #expect(TurnKeeper.verdict(for: Self.record(), error: .networkConnectionLost, slept: false,
                                   consequential: true) == .giveUp)
        #expect(TurnKeeper.stoppedNote.contains("sends or pays"))
    }

    @Test("the record carries its thread, and the file is the person's alone")
    func threadAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turn-keeper-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("turns/inflight.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        var r = Self.record()
        r.thread = "THREAD-1"
        TurnKeeper.write(r, to: url)
        #expect(try #require(TurnKeeper.read(from: url)).thread == "THREAD-1")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
    }

    @Test("no sleep, no resume — a break on an awake Mac is the gateway's to explain")
    func awakeBreakIsNotResumed() {
        #expect(TurnKeeper.verdict(for: Self.record(), error: .networkConnectionLost, slept: false) == .giveUp)
        #expect(TurnKeeper.verdict(for: Self.record(), error: .timedOut, slept: false) == .giveUp)
    }

    @Test("only the failures a sleep produces count; a cancel or a bad response never do")
    func shape() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet] {
            #expect(TurnKeeper.isSleepShaped(code), "\(code)")
        }
        for code: URLError.Code in [.cancelled, .badServerResponse, .userAuthenticationRequired, .cannotParseResponse] {
            #expect(!TurnKeeper.isSleepShaped(code), "\(code)")
            #expect(TurnKeeper.verdict(for: Self.record(), error: code, slept: true) == .giveUp, "\(code)")
        }
    }

    @Test("a record from a quit is picked up while fresh, and never after the window or a resume")
    func leftover() {
        #expect(TurnKeeper.leftover(Self.record(age: 60)) != nil)
        #expect(TurnKeeper.leftover(Self.record(age: TurnKeeper.relaunchWindow + 1)) == nil)
        #expect(TurnKeeper.leftover(Self.record(resumed: 1, age: 60)) == nil)
        #expect(TurnKeeper.leftover(nil) == nil)
    }

    @Test("the record round-trips through the file and clear removes it")
    func file() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turn-keeper-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("turns/inflight.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TurnKeeper.read(from: url) == nil)
        let r = Self.record(resumed: 1)
        TurnKeeper.write(r, to: url)
        let back = try #require(TurnKeeper.read(from: url))
        #expect(back.text == r.text && back.sessionID == "s1" && back.resumed == 1)
        #expect(abs(back.startedAt.timeIntervalSince(r.startedAt)) < 1)
        TurnKeeper.clear(url)
        #expect(TurnKeeper.read(from: url) == nil)
    }

    @Test("the work assertion holds while a reply is owed and lets go once, however many times it is told")
    func assertion() {
        let a = WorkAssertion()
        #expect(!a.isHeld)
        a.set(held: true); a.set(held: true)
        #expect(a.isHeld)
        a.set(held: false); a.set(held: false)
        #expect(!a.isHeld)
    }
}
