import Foundation
import Testing
@testable import MoeDictation

struct DictationHistoryTests {

    private func fresh(cap: Int = 2000) -> DictationHistory {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-history-\(UUID().uuidString)", isDirectory: true)
        return DictationHistory(url: dir.appendingPathComponent("dictation-history.jsonl"), cap: cap)
    }

    private func entry(_ text: String, app: String? = "Mail", polished: Bool = false,
                       at: Date = Date()) -> DictationHistory.Entry {
        DictationHistory.Entry(at: at, appBundleID: app.map { "com.apple.\($0)" },
                               appName: app, polished: polished, text: text)
    }

    @Test func emptyWhenThereIsNoFile() {
        #expect(fresh().entries().isEmpty)
        #expect(fresh().search("x").isEmpty)
    }

    @Test func appendThenReadBackRoundTrips() throws {
        let h = fresh()
        let e = entry("Hello there,\nsecond line", polished: true)
        try h.append(e)
        let back = h.entries()
        #expect(back.count == 1)
        #expect(back[0].id == e.id)
        #expect(back[0].text == e.text)
        #expect(back[0].polished)
        #expect(back[0].chars == e.text.count)
        #expect(back[0].appName == "Mail")
        #expect(back[0].firstLine == "Hello there,")
        #expect(abs(back[0].at.timeIntervalSince(e.at)) < 1)   // ISO 8601, whole seconds
    }

    @Test func recentIsNewestFirst() throws {
        let h = fresh()
        try h.append(entry("one"))
        try h.append(entry("two"))
        try h.append(entry("three"))
        #expect(h.recent().map(\.text) == ["three", "two", "one"])
    }

    @Test func fileIsOwnerOnly() throws {
        let h = fresh()
        try h.append(entry("secret"))
        let mode = try FileManager.default.attributesOfItem(atPath: h.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try h.delete(id: "nope")           // a rewrite keeps it that way
        let after = try FileManager.default.attributesOfItem(atPath: h.url.path)[.posixPermissions] as? Int
        #expect(after == 0o600)
    }

    @Test func rotatesOldestPastTheCap() throws {
        let h = fresh(cap: 3)
        for i in 1...5 { try h.append(entry("entry \(i)")) }
        #expect(h.entries().map(\.text) == ["entry 3", "entry 4", "entry 5"])
    }

    @Test func deleteRemovesJustThatEntry() throws {
        let h = fresh()
        let a = entry("a"), b = entry("b"), c = entry("c")
        try h.append(a); try h.append(b); try h.append(c)
        try h.delete(id: b.id)
        #expect(h.entries().map(\.id) == [a.id, c.id])
    }

    @Test func clearEmptiesTheFile() throws {
        let h = fresh()
        try h.append(entry("a"))
        try h.clear()
        #expect(h.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.url.path))
    }

    @Test func searchMatchesTextAndAppCaseInsensitively() throws {
        let h = fresh()
        try h.append(entry("Send the deck to Siobhan", app: "Mail"))
        try h.append(entry("lunch at noon", app: "Messages"))
        try h.append(entry("ship it", app: "Slack"))
        #expect(h.search("SIOBHAN").map(\.text) == ["Send the deck to Siobhan"])
        #expect(h.search("messages").map(\.text) == ["lunch at noon"])
        #expect(h.search("  ").count == 3)
        #expect(h.search("zzz").isEmpty)
    }

    @Test func malformedLineIsSkipped() throws {
        let h = fresh()
        try h.append(entry("good one"))
        let handle = try FileHandle(forWritingTo: h.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        try h.append(entry("another good one"))
        #expect(h.entries().map(\.text) == ["good one", "another good one"])
    }

    @Test func rotationDropsMalformedLinesToo() throws {
        let h = fresh(cap: 2)
        try h.append(entry("1"))
        let handle = try FileHandle(forWritingTo: h.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\n".utf8))
        try handle.close()
        try h.append(entry("2"))
        try h.append(entry("3"))
        #expect(h.entries().map(\.text) == ["2", "3"])
        let raw = try String(contentsOf: h.url, encoding: .utf8)
        #expect(!raw.contains("garbage"))
    }
}
