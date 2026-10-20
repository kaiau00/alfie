import Foundation
import Testing
@testable import MoeDictation

/// The two pure decisions behind the local-model tier: what a server's
/// catalogue means, and which model to pick from it. `LocalModelServer` (app
/// target) does the networking and delegates both here, so these test the
/// real implementation rather than a copy of it.
@Suite("LocalModelServer parsing")
struct LocalModelServerTests {

    @Test("an OpenAI-shaped model list is read")
    func parsesModelList() {
        let json = #"{"object":"list","data":[{"id":"llama3.2:3b"},{"id":"qwen2.5-7b-instruct"}]}"#
        #expect(LocalModelChoice.modelIDs(from: Data(json.utf8)) == ["llama3.2:3b", "qwen2.5-7b-instruct"])
    }

    /// A server that is up with nothing pulled looks identical from outside
    /// until it is asked to generate, so an empty list has to be a real
    /// answer rather than a parse failure.
    @Test("a running server with no models is an empty list, not an error")
    func emptyList() {
        #expect(LocalModelChoice.modelIDs(from: Data(#"{"object":"list","data":[]}"#.utf8)).isEmpty)
    }

    @Test("junk parses to nothing rather than crashing")
    func junk() {
        #expect(LocalModelChoice.modelIDs(from: Data("not json".utf8)).isEmpty)
        #expect(LocalModelChoice.modelIDs(from: Data("{}".utf8)).isEmpty)
        #expect(LocalModelChoice.modelIDs(from: Data(#"{"data":[{"nope":1}]}"#.utf8)).isEmpty)
    }

    /// Smallest wins: a rewrite is mechanical, and the whole point of this
    /// tier is being faster than the cloud one.
    @Test("the smallest model is preferred")
    func prefersSmallest() {
        #expect(LocalModelChoice.preferredModel(from: ["qwen2.5-7b-instruct", "llama3.2:3b"]) == "llama3.2:3b")
        #expect(LocalModelChoice.preferredModel(from: ["llama3:70b", "phi4-mini-3.8b"]) == "phi4-mini-3.8b")
    }

    @Test("a model with no size in its name is still usable")
    func noSizeInName() {
        #expect(LocalModelChoice.preferredModel(from: ["mistral", "codestral"]) == "mistral")
        #expect(LocalModelChoice.preferredModel(from: []) == nil)
    }

    /// A sized name must beat an unsized one — otherwise a list whose first
    /// entry happens to be a 70B would win on position alone.
    @Test("a sized name beats an unsized one")
    func sizedBeatsUnsized() {
        #expect(LocalModelChoice.preferredModel(from: ["some-big-model", "llama3.2:1b"]) == "llama3.2:1b")
    }

    /// Version digits are not sizes: "llama3.2" must not read as 3.2B and
    /// outrank a genuine 1B.
    @Test("version numbers are not mistaken for sizes")
    func versionsAreNotSizes() {
        #expect(LocalModelChoice.preferredModel(from: ["llama3.2:8b", "tinyllama:1.1b"]) == "tinyllama:1.1b")
    }
}
