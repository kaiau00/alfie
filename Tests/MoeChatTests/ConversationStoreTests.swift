import Foundation
import Testing
@testable import MoeChat

/// Conversation persistence. These matter more than most: the bug being fixed
/// here was silent, permanent data loss — ⌘N emptied an in-memory array and
/// there was no way back.
struct ConversationStoreTests {

    private func tempStore(cap: Int = 400) -> ConversationStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-convo-tests-\(UUID().uuidString)", isDirectory: true)
        return ConversationStore(directory: dir, cap: cap)
    }

    private func convo(_ said: String, at: Date = Date()) -> ConversationStore.Conversation {
        ConversationStore.Conversation(
            startedAt: at, updatedAt: at,
            turns: [.init(role: .you, text: said, at: at),
                    .init(role: .moe, text: "Sure.", at: at)])
    }

    // MARK: Round trip

    @Test func aSavedConversationComesBackWithItsTurns() throws {
        let store = tempStore()
        let original = convo("what's in the Vasquez deck?")
        try store.save(original)

        let loaded = try #require(store.load(id: original.id))
        #expect(loaded.id == original.id)
        #expect(loaded.turns.count == 2)
        #expect(loaded.turns.first?.text == "what's in the Vasquez deck?")
        #expect(loaded.turns.first?.role == .you)
    }

    @Test func savingTwiceUpdatesRatherThanDuplicates() throws {
        let store = tempStore()
        var c = convo("first")
        try store.save(c)
        c.turns.append(.init(role: .you, text: "second"))
        c.updatedAt = Date()
        try store.save(c)

        #expect(store.all().count == 1)
        #expect(store.load(id: c.id)?.turns.count == 3)
    }

    // MARK: Ordering

    @Test func listingIsNewestActivityFirst() throws {
        let store = tempStore()
        let old = convo("older", at: Date(timeIntervalSince1970: 1_000))
        let new = convo("newer", at: Date(timeIntervalSince1970: 2_000))
        try store.save(old)
        try store.save(new)

        #expect(store.all().map(\.id) == [new.id, old.id])
    }

    // MARK: Titles

    @Test func theTitleIsTheFirstThingYouSaid() {
        let c = ConversationStore.Conversation(turns: [
            .init(role: .system, text: "Connected."),
            .init(role: .you, text: "reconcile the forecast"),
            .init(role: .moe, text: "Three things stand out…"),
        ])
        #expect(c.title == "reconcile the forecast")
    }

    @Test func aLongTitleIsTruncatedOnOneLine() {
        let long = String(repeating: "a", count: 90)
        let c = ConversationStore.Conversation(turns: [.init(role: .you, text: long)])
        #expect(c.title.count == 48)          // 47 + the ellipsis
        #expect(c.title.hasSuffix("…"))
    }

    @Test func onlyTheFirstLineBecomesTheTitle() {
        let c = ConversationStore.Conversation(turns: [
            .init(role: .you, text: "push the review\nand reconcile the sheet"),
        ])
        #expect(c.title == "push the review")
    }

    @Test func aConversationWithNothingSaidHasAFallbackTitle() {
        #expect(ConversationStore.Conversation().title == "New conversation")
    }

    // MARK: Empty threads

    @Test func systemNoticesAloneDoNotMakeAConversationWorthKeeping() throws {
        let store = tempStore()
        let c = ConversationStore.Conversation(turns: [
            .init(role: .system, text: "Connected."),
        ])
        #expect(c.isEmpty)
        try store.save(c)
        #expect(store.all().isEmpty)
    }

    @Test func savingAnEmptyThreadRemovesOneAlreadyOnDisk() throws {
        let store = tempStore()
        var c = convo("something")
        try store.save(c)
        #expect(store.all().count == 1)

        c.turns = []
        try store.save(c)
        #expect(store.all().isEmpty)
    }

    // MARK: Pruning

    @Test func theOldestThreadsFallOffTheCap() throws {
        let store = tempStore(cap: 3)
        for i in 0..<5 {
            try store.save(convo("thread \(i)", at: Date(timeIntervalSince1970: Double(i) * 100)))
        }
        let kept = store.all()
        #expect(kept.count == 3)
        #expect(kept.map(\.title) == ["thread 4", "thread 3", "thread 2"])
    }

    // MARK: Robustness

    @Test func aCorruptFileIsSkippedRatherThanFatal() throws {
        let store = tempStore()
        let good = convo("readable")
        try store.save(good)
        try Data("this is not json".utf8)
            .write(to: store.directory.appendingPathComponent("broken.json"))

        let all = store.all()
        #expect(all.count == 1)
        #expect(all.first?.id == good.id)
    }

    @Test func readingAStoreThatDoesNotExistYetIsEmptyNotAThrow() {
        #expect(tempStore().all().isEmpty)
    }

    /// An id is normally a UUID, but nothing may write outside the directory.
    @Test func anIdCannotEscapeTheDirectory() throws {
        let store = tempStore()
        let sneaky = ConversationStore.Conversation(
            id: "../../escaped",
            turns: [.init(role: .you, text: "hello")])
        try store.save(sneaky)

        let parent = store.directory.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escaped.json").path))
        #expect(store.all().count == 1)
    }

    // MARK: Search

    @Test func searchMatchesTitlesAndTurnText() throws {
        let store = tempStore()
        try store.save(convo("the Vasquez deck"))
        try store.save(convo("flights to Lisbon"))

        #expect(store.search("vasquez").count == 1)
        #expect(store.search("Sure.").count == 2)      // both have Moe's reply
        #expect(store.search("").count == 2)
        #expect(store.search("nothing here").isEmpty)
    }

    // MARK: Deletion

    @Test func deletingLeavesTheRestAlone() throws {
        let store = tempStore()
        let a = convo("keep me")
        let b = convo("delete me")
        try store.save(a)
        try store.save(b)

        try store.delete(id: b.id)
        #expect(store.all().map(\.id) == [a.id])

        try store.deleteAll()
        #expect(store.all().isEmpty)
    }
}
