import Foundation
import Testing
@testable import Moe

/// Logs under ~/.moe/logs that no writer bounds are cut back on every launch
/// and `--sync`; the install receipts beside them never are.
struct LogJanitorTests {

    private func tempLogs() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logjanitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Numbered lines until the file passes `bytes`.
    private func fill(_ url: URL, bytes: Int) throws -> Int {
        var text = ""
        var n = 0
        while text.utf8.count < bytes {
            text += "line \(n) " + String(repeating: "x", count: 80) + "\n"
            n += 1
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return n
    }

    private func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    @Test("an oversized launchd .err is cut to its newest megabyte, at a line boundary")
    func trimsErr() throws {
        let dir = try tempLogs()
        defer { try? FileManager.default.removeItem(at: dir) }
        let err = dir.appendingPathComponent("com.memoe.app.err")
        let lines = try fill(err, bytes: LogJanitor.limit + 200_000)

        #expect(LogJanitor.sweep(in: dir) == ["com.memoe.app.err"])

        #expect(size(err) <= LogJanitor.keep)
        #expect(size(err) > LogJanitor.keep - 200)
        let text = try String(contentsOf: err, encoding: .utf8)
        #expect(text.hasPrefix("line "), "starts on a whole line")
        #expect(text.hasSuffix("line \(lines - 1) " + String(repeating: "x", count: 80) + "\n"),
                "the newest line survives")
    }

    @Test("the install receipts and self-rotating logs are never touched, however large")
    func leavesReceipts() throws {
        let dir = try tempLogs()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = LogJanitor.limit + 100_000
        var before: [String: Int] = [:]
        for name in ["installs.log", "overrides.log", "moe.log", "moe.log.1",
                     "hermes-gateway.log", "activity.jsonl", "situations.jsonl"] {
            let url = dir.appendingPathComponent(name)
            _ = try fill(url, bytes: big)
            before[name] = size(url)
        }

        #expect(LogJanitor.sweep(in: dir).isEmpty)

        for (name, bytes) in before {
            #expect(size(dir.appendingPathComponent(name)) == bytes, "\(name) changed")
        }
    }

    @Test("each named plugin log is managed; a small one is left alone")
    func namedAndSmall() throws {
        let dir = try tempLogs()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in LogJanitor.named {
            _ = try fill(dir.appendingPathComponent(name), bytes: LogJanitor.limit + 10)
        }
        let small = dir.appendingPathComponent("com.moe.assistant.jobs.err")
        _ = try fill(small, bytes: 10_000)
        let smallBytes = size(small)

        #expect(Set(LogJanitor.sweep(in: dir)) == LogJanitor.named)
        #expect(size(small) == smallBytes)
    }

    @Test("Log.rotate keeps exactly one previous generation")
    func rotateKeepsOne() throws {
        let dir = try tempLogs()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("moe.log")
        try "first\n".write(to: url, atomically: true, encoding: .utf8)
        Log.rotate(url)
        try "second\n".write(to: url, atomically: true, encoding: .utf8)
        Log.rotate(url)

        let old = try String(contentsOf: URL(fileURLWithPath: url.path + ".1"), encoding: .utf8)
        #expect(old == "second\n", "the older generation is dropped, not kept as .2")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path + ".2"))
    }
}
