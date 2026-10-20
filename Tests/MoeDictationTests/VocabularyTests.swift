import Foundation
import Testing
@testable import MoeDictation

/// Each test gets its own temp directory; the user's `~/.moe` is never read.
final class VocabularyTests {

    private let dir: URL
    private let file: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-vocab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("vocabulary.txt")
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, mtime: Date? = nil) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
    }

    @Test func missingFileIsEmptyAndHarmless() {
        let v = Vocabulary(url: file)
        #expect(v.entries == [:])
        #expect(v.apply(to: "hello world") == "hello world")
    }

    @Test func termsCommentsAndReplacements() throws {
        try write("""
        # names
        Kubernetes
        cooper netties => Kubernetes   # trailing comment

        acme corp => AcmeCorp
        """)
        let v = Vocabulary(url: file)
        #expect(v.entries == [
            "kubernetes": "Kubernetes",
            "cooper netties": "Kubernetes",
            "acme corp": "AcmeCorp",
        ])
        #expect(v.apply(to: "deploy to KUBERNETES at Acme Corp via cooper netties")
                == "deploy to Kubernetes at AcmeCorp via Kubernetes")
    }

    @Test func wholeWordOnly() throws {
        try write("Dan")
        let v = Vocabulary(url: file)
        #expect(v.apply(to: "dan and danny went dancing, dan.") == "Dan and danny went dancing, Dan.")
    }

    @Test func termsWithSymbolsAndRegexCharacters() throws {
        try write("C++\n.net => .NET\n")
        let v = Vocabulary(url: file)
        #expect(v.apply(to: "c++ and .net and cnet") == "C++ and .NET and cnet")
    }

    @Test func longestTermWins() throws {
        try write("new york => New York\nnew york times => New York Times\n")
        let v = Vocabulary(url: file)
        #expect(v.apply(to: "the new york times in new york") == "the New York Times in New York")
    }

    @Test func reloadsWhenMtimeChanges() throws {
        try write("alpha => Alpha", mtime: Date(timeIntervalSinceNow: -100))
        let v = Vocabulary(url: file)
        #expect(v.apply(to: "alpha beta") == "Alpha beta")

        try write("beta => Beta", mtime: Date(timeIntervalSinceNow: -50))
        #expect(v.apply(to: "alpha beta") == "alpha Beta")
    }

    @Test func deletedFileClearsTerms() throws {
        try write("alpha => Alpha")
        let v = Vocabulary(url: file)
        #expect(v.apply(to: "alpha") == "Alpha")
        try FileManager.default.removeItem(at: file)
        #expect(v.apply(to: "alpha") == "alpha")
    }

    @Test func bomAndCrlfTolerated() throws {
        // A Windows editor or a copy-paste can leave a BOM and CRLF endings.
        try Data([0xEF, 0xBB, 0xBF] + Array("Kubernetes\r\nfoo => Bar\r\n".utf8)).write(to: file)
        let v = Vocabulary(url: file)
        #expect(v.entries == ["kubernetes": "Kubernetes", "foo": "Bar"])
        let m = Vocabulary(lines: ["\u{FEFF}Kubernetes\r", "foo=>Bar\r"])
        #expect(m.entries == ["kubernetes": "Kubernetes", "foo": "Bar"])
    }

    @Test func dottedTermIsWholeWord() {
        let v = Vocabulary(lines: ["Node.js"])
        #expect(v.apply(to: "node.js and xnode.js and node.jsx and node js") == "Node.js and xnode.js and node.jsx and node js")
    }

    @Test func unreadableFileIsEmptyAndHarmless() throws {
        try #require(geteuid() != 0, "root ignores file modes")
        try write("alpha => Alpha")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let v = Vocabulary(url: file)
        #expect(v.entries == [:])
        #expect(v.apply(to: "alpha") == "alpha")
    }

    @Test func concurrentApplyAndReloadDoesNotCrash() throws {
        try write("alpha => Alpha", mtime: Date(timeIntervalSinceNow: -100))
        let v = Vocabulary(url: file)
        let group = DispatchGroup()
        for i in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<200 { _ = v.apply(to: "alpha beta \(i)") }
            }
        }
        for k in 0..<20 {
            try write("alpha => Alpha\nbeta => Beta\(k)", mtime: Date(timeIntervalSinceNow: Double(k - 50)))
            _ = v.entries
        }
        group.wait()
        // The point is no crash under concurrent apply/reload. Which write
        // the last reload saw is timing-dependent (mtime stamps in the same
        // second collide), so only assert that a fresh, clearly newer file
        // wins.
        try write("alpha => Alpha\nbeta => Beta19", mtime: Date(timeIntervalSinceNow: 60))
        #expect(v.apply(to: "alpha beta") == "Alpha Beta19")
    }

    @Test func inMemoryLines() {
        let v = Vocabulary(lines: ["# ignored", "", "foo => Bar"])
        #expect(v.apply(to: "FOO foo food") == "Bar Bar food")
    }

    // MARK: Several sources

    private func writeSource(_ name: String, _ text: String, mtime: Date? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    @Test func sourcesMergeAndTheFirstWinsOnConflict() throws {
        let user = try writeSource("vocabulary.txt", "dan => Dan\nshavon => Siobhan")
        let learned = try writeSource("vocabulary-learned.txt", "shavon => Shavonne\nnyle => Niall")
        let contacts = try writeSource("vocabulary-contacts.txt", "Dan\nNiall\nMcGrath")
        let v = Vocabulary(sources: [user, learned, contacts])
        #expect(v.entries == [
            "dan": "Dan", "shavon": "Siobhan", "nyle": "Niall", "niall": "Niall", "mcgrath": "McGrath",
        ])
        #expect(v.apply(to: "shavon and nyle mcgrath") == "Siobhan and Niall McGrath")
        #expect(v.url == user)
    }

    @Test func missingSourcesAreEmpty() throws {
        let learned = try writeSource("vocabulary-learned.txt", "nyle => Niall")
        let v = Vocabulary(sources: [dir.appendingPathComponent("vocabulary.txt"), learned,
                                     dir.appendingPathComponent("vocabulary-contacts.txt")])
        #expect(v.entries == ["nyle": "Niall"])
    }

    @Test func aChangeToAnySourceReloads() throws {
        let user = try writeSource("vocabulary.txt", "alpha => Alpha", mtime: Date(timeIntervalSinceNow: -100))
        let contacts = try writeSource("vocabulary-contacts.txt", "Beta", mtime: Date(timeIntervalSinceNow: -100))
        let v = Vocabulary(sources: [user, contacts])
        #expect(v.apply(to: "alpha beta gamma") == "Alpha Beta gamma")
        _ = try writeSource("vocabulary-contacts.txt", "Beta\nGamma", mtime: Date(timeIntervalSinceNow: -50))
        #expect(v.apply(to: "alpha beta gamma") == "Alpha Beta Gamma")
        try FileManager.default.removeItem(at: user)
        #expect(v.apply(to: "alpha beta gamma") == "alpha Beta Gamma")
    }

    @Test func additionalTermsSitBelowEveryFile() throws {
        let user = try writeSource("vocabulary.txt", "dan => Dan")
        let v = Vocabulary(sources: [user])
        v.additionalTerms = ["dan => DAN", "siobhan", "nyle => Niall"]
        #expect(v.apply(to: "dan siobhan nyle") == "Dan siobhan Niall")
        // A heard form equal to the lowercased term is the bare-term syntax.
        #expect(v.additionalTerms == ["DAN", "nyle => Niall", "siobhan"])
        v.additionalTerms = []
        #expect(v.apply(to: "dan siobhan nyle") == "Dan siobhan nyle")
    }

    @Test func promptTermsPreferEarlierSourcesAndAreCapped() throws {
        let user = try writeSource("vocabulary.txt", "cooper netties => Kubernetes\nZed")
        let contacts = try writeSource("vocabulary-contacts.txt", "Aaron\nBea\nZed\nKubernetes")
        let v = Vocabulary(sources: [user, contacts])
        #expect(v.promptTerms(limit: 10) == ["Kubernetes", "Zed", "Aaron", "Bea"])
        #expect(v.promptTerms(limit: 3) == ["Kubernetes", "Zed", "Aaron"])
        #expect(v.promptTerms(limit: 0) == [])
    }

    @Test func twoThousandTermsBuildAndApplyQuickly() {
        // A full Contacts cache: one alternation of 2,000 escaped names.
        // Measured ~11 ms to build and ~2.5 ms per 240-word apply (debug).
        var names = (0..<2_000).map { "Name\($0)xyz\($0 % 7)abc" }
        names += ["Siobhan", "O'Brien", "Anna-Maria", "A.B.", "McGrath"]
        let t0 = Date()
        let v = Vocabulary(lines: names)
        let sentence = "the quick brown fox jumps over siobhan and o'brien while anna-maria watches"
        let text = Array(repeating: sentence, count: 20).joined(separator: " ")
        #expect(v.apply(to: text).contains("Siobhan and O'Brien while Anna-Maria"))
        let build = Date().timeIntervalSince(t0)
        let t1 = Date()
        for _ in 0..<5 { _ = v.apply(to: text) }
        let apply = Date().timeIntervalSince(t1) / 5
        #expect(build < 0.25, "build took \(build * 1000) ms")
        #expect(apply < 0.05, "apply took \(apply * 1000) ms")
    }
}
