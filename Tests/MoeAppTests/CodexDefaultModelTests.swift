import Foundation
import Testing
@testable import Moe

/// OpenAI retires gpt-5.5 from ChatGPT and Codex on every plan on 2026-10-14
/// (learn.chatgpt.com/docs/pricing, read 2026-09-24); the API keeps it. A
/// ChatGPT sign-in that still defaulted to it would stop thinking that day,
/// on the Mac and on the away machine alike.
struct CodexDefaultModelTests {
    static let retiredOnChatGPT: Set<String> = ["gpt-5.5"]

    @Test("a ChatGPT sign-in never defaults to a model ChatGPT has retired")
    func codexDefaultIsNotRetired() {
        let model = BrainProviderKind.codex.defaultModel
        #expect(model == "gpt-5.6-sol")
        #expect(!Self.retiredOnChatGPT.contains(model))
        #expect(BrainProviderKind.codex.curatedModels.contains(model))
    }
}
