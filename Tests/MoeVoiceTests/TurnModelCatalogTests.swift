import Foundation
import Testing
@testable import MoeVoice

/// Which Smart Turn file a launch uses, and that a better model can be put in
/// front of v3.2 without ever losing it or waiting on the network.
struct TurnModelCatalogTests {

    typealias C = TurnModelCatalog

    /// A stand-in for a model listed before v3.2, pinned by hash.
    private let candidate = C.Model(name: "candidate", file: "candidate.onnx",
                                    url: URL(string: "https://example.invalid/candidate.onnx")!,
                                    sha256: String(repeating: "a", count: 64), bytes: 0)

    /// What ships is exactly the file Moe always loaded: v3.2, from Hugging Face.
    @Test func v32IsWhatShips() {
        #expect(C.preference == [C.upstream])
        #expect(C.upstream.file == "smart-turn-v3.2-cpu.onnx")
        #expect(C.upstream.url.absoluteString == "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main/smart-turn-v3.2-cpu.onnx")
        #expect(C.upstream.sha256 == nil)
    }

    /// A fresh Mac downloads the preferred model first and falls back in order.
    @Test func aFreshMacFetchesInOrder() {
        let plan = C.loadPlan([candidate, C.upstream]) { _ in false }
        #expect(plan.attempts.map(\.model.name) == ["candidate", "smart-turn-v3.2"])
        let allDownload = plan.attempts.allSatisfy { $0.download }
        #expect(allDownload)
        #expect(plan.fetchLater.isEmpty)
    }

    /// A Mac holding only v3.2 loads it straight away — voice does not wait on
    /// a download — and fetches the preferred one in the background.
    @Test func whatIsOnDiskLoadsFirstAndTheRestComesLater() {
        let plan = C.loadPlan([candidate, C.upstream]) { $0 == C.upstream }
        #expect(plan.attempts.first == .init(model: C.upstream, download: false))
        #expect(plan.attempts.map(\.model.name) == ["smart-turn-v3.2", "candidate"])
        #expect(plan.fetchLater == [candidate])
        let both = C.loadPlan([candidate, C.upstream]) { _ in true }
        #expect(both.attempts.first == .init(model: candidate, download: false))
        #expect(both.fetchLater.isEmpty)
    }

    /// A pinned model is checked by hash, so a truncated or substituted file is
    /// refused; v3.2 only has to be plausibly a model.
    @Test func aPinnedModelIsCheckedByHashAndV32BySize() {
        let junk = Data(repeating: 7, count: 2_000_000)
        #expect(!C.accepts(candidate, data: junk))
        #expect(C.accepts(C.upstream, data: junk))
        #expect(!C.accepts(C.upstream, data: Data(repeating: 7, count: 1000)))
        let pinned = C.Model(name: "x", file: "x.onnx", url: URL(string: "https://example.invalid/x")!,
                             sha256: C.sha256Hex(junk), bytes: junk.count)
        #expect(C.accepts(pinned, data: junk))
        var one = junk; one[0] = 8
        #expect(!C.accepts(pinned, data: one))
    }

    /// The benches pin a model by name or path, and nothing else is tried.
    @Test func anOverridePinsOneModel() {
        #expect(C.order(override: nil) == C.preference)
        #expect(C.order(override: " ") == C.preference)
        #expect(C.order(override: "smart-turn-v3.2").map(\.name) == ["smart-turn-v3.2"])
        let byPath = C.order(override: "/tmp/some-model.onnx")
        #expect(byPath.count == 1 && byPath[0].url.isFileURL && byPath[0].name == "some-model")
    }
}
