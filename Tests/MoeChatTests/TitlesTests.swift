import Foundation
import Testing
@testable import MoeChat

/// Short AI names for the Chat list (the owner, 2026-09-25: "auto-generated
/// by the AI … as cheap as possible … very minimal").
struct TitlesTests {

    private func store() -> ConversationStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-titles-tests-\(UUID().uuidString)", isDirectory: true)
        return ConversationStore(directory: dir)
    }

    private func thread(_ id: String, _ first: String) -> ConversationStore.Conversation {
        .init(id: id, turns: [.init(role: .you, text: first), .init(role: .moe, text: "Done.")])
    }

    @Test func aNamedThreadShowsItsNameAndKeepsItAcrossRewrites() throws {
        let s = store()
        try s.save(thread("t1", "I want to create a— I want to create a plan for the launch"))
        #expect(s.load(id: "t1")?.title.hasPrefix("I want to create a") == true)
        try s.setTitle("Launch plan", for: "t1")
        #expect(s.load(id: "t1")?.title == "Launch plan")
        // The thread file is rewritten (a new turn, a re-projection): the name stays.
        try s.save(thread("t1", "I want to create a— I want to create a plan for the launch"))
        #expect(s.all().first?.title == "Launch plan")
        // And search finds it by its name.
        #expect(s.search("launch plan").map(\.id) == ["t1"])
    }

    @Test func theNamesFileIsNeverReadAsAThread() throws {
        let s = store()
        try s.save(thread("t1", "hello"))
        try s.setTitle("Greeting", for: "t1")
        #expect(s.all().count == 1)
    }

    @Test func deletingAThreadForgetsItsName() throws {
        let s = store()
        try s.save(thread("t1", "hello"))
        try s.setTitle("Greeting", for: "t1")
        try s.delete(id: "t1")
        #expect(s.titles()["t1"] == nil)
    }

    @Test func aReplyIsKeptOnlyWhenItIsAName() {
        #expect(TitleRules.accept("Book table at Nopa") == "Book table at Nopa")
        #expect(TitleRules.accept("\"Launch pricing.\"") == "Launch pricing")
        #expect(TitleRules.accept("**Title:** Trip to Yunnan") == "Trip to Yunnan")
        #expect(TitleRules.accept("Sure! Here is a title for this conversation about your trip to China and more") == nil)
        #expect(TitleRules.accept("") == nil)
    }

    @Test func onlyYourFirstWordsGoIn() {
        let long = String(repeating: "a", count: 2000)
        #expect(TitleRules.user(firstMessage: long).count < 360)
    }

    @Test func aThreadIsNamedOnceAndOnlyAfterAnAnswer() {
        #expect(TitleRules.wants(hasTitle: false, firstMessage: "plan my trip", answered: true))
        #expect(!TitleRules.wants(hasTitle: true, firstMessage: "plan my trip", answered: true))
        #expect(!TitleRules.wants(hasTitle: false, firstMessage: "plan my trip", answered: false))
        #expect(!TitleRules.wants(hasTitle: false, firstMessage: nil, answered: true))
    }
}
