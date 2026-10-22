import Foundation
import Testing
@testable import Moe

/// Memory › Import from ChatGPT or Claude (learn/import_memory.py).
struct ImportMemoryTests {
    @Test("the question the sheet shows is the import step's own, word for word")
    func samePrompt() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let py = try String(contentsOf: repo.appendingPathComponent("moe-home/learn/import_memory.py"), encoding: .utf8)
        // The Python spells it as adjacent string literals; join them.
        let start = try #require(py.range(of: "PROMPT = ("))
        let end = try #require(py.range(of: ")", range: start.upperBound..<py.endIndex))
        let joined = py[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
                return String(line[line.index(after: a)..<b])
            }.joined()
        #expect(joined == ImportMemorySheet.prompt)
    }

    @Test("the answer is read from the last JSON line, whatever else was printed")
    func parseAndSay() {
        let out = "distil: chunk 1/1\n{\"added\": 3, \"refreshed\": 1, \"replaced\": 0, \"questions\": 2}\n"
        let r = ImportMemorySheet.parse(out)
        #expect(ImportMemorySheet.summary(r) == "3 new things kept. 1 Alfie already knew. 2 disagree with what Alfie knows, under To check.")
        #expect(ImportMemorySheet.summary(["added": 0]) == "Nothing to keep in it.")
        #expect(ImportMemorySheet.summary(["left_out": 2, "skipped": 1])
                == "1 left alone because you'd already said otherwise. 2 left out: private details or instructions to the other assistant.")
        #expect(ImportMemorySheet.parse("{\"error\": \"That's empty.\"}")["error"] as? String == "That's empty.")
    }
}
