import Foundation
import Testing
import MoeChat
@testable import MoeLedger

/// What the app does with records that arrived from another device
/// (`CloudSync` → `ConversationLedger.reproject`): the thread's file is
/// rewritten from the ledger so the window shows the other side's turns, and
/// a deletion that arrived as a record takes the file *and the key* with it.
struct ReprojectTests {

    private let sunday = Date(timeIntervalSince1970: 1_756_000_000)

    private func replicas(_ label: String) -> (mac: Appender, phone: Appender) {
        let root = scratchRoot(label)
        let mac = Appender.make(name: "mac-9f3c", root: root.appendingPathComponent("mac"),
                                ledgerDirectory: root.appendingPathComponent("mac/ledger"),
                                clock: FakeClock(sunday))
        let phone = Appender.make(name: "phone-1", root: root.appendingPathComponent("phone"),
                                  ledgerDirectory: root.appendingPathComponent("phone/ledger"),
                                  clock: FakeClock(sunday))
        return (mac, phone)
    }

    @Test func aTurnFromTheOtherDeviceReachesTheThreadsFile() throws {
        let (mac, phone) = replicas("reproject-turn")
        try mac.say("from the notch", in: "th-1", turn: "m1")
        try Relay.handKey(for: "th-1", from: mac, to: phone)
        try Relay.sync(mac, phone)
        phone.clock.advance(30)
        try phone.say("from the phone", in: "th-1", turn: "p1", role: .moe)

        // The Mac adopts the phone's record the way `SyncClient.pull` does —
        // straight into the ledger — and nothing on disk has changed yet.
        try Relay.deliver(Relay.records(of: phone), to: mac)
        #expect(mac.store.load(id: "th-1")?.turns.map(\.id) == ["m1"])

        let touched = try mac.conversations.reproject(threads: ["th-1", "th-1"])
        #expect(touched == ["th-1"])
        #expect(mac.store.load(id: "th-1")?.turns.map(\.id) == ["m1", "p1"])
        #expect(mac.store.load(id: "th-1")?.turns.last?.text == "from the phone")
    }

    @Test func aDeletionThatArrivedAsARecordTakesTheKeyToo() throws {
        let (mac, phone) = replicas("reproject-delete")
        try mac.say("something private", in: "th-1", turn: "m1")
        try mac.say("something else", in: "th-2", turn: "m2")
        for thread in ["th-1", "th-2"] { try Relay.handKey(for: thread, from: mac, to: phone) }
        try Relay.sync(mac, phone)
        #expect(mac.conversations.deletedThreads().isEmpty)

        phone.clock.advance(60)
        try phone.conversations.delete(id: "th-1")
        try Relay.deliver(Relay.records(of: phone), to: mac)
        #expect(mac.conversations.deletedThreads() == ["th-1"])
        // Adopted, not yet applied: the file and the key are still there.
        #expect(mac.store.load(id: "th-1") != nil)
        #expect(mac.keyring.has(thread: "th-1"))

        try mac.conversations.reproject(threads: ["th-1"])
        #expect(mac.store.load(id: "th-1") == nil, "the deleted thread's file should be gone")
        #expect(!mac.keyring.has(thread: "th-1"), "and its key with it")
        #expect(mac.keyring.has(thread: "th-2"), "the other thread is untouched")
        #expect(mac.store.load(id: "th-2")?.turns.map(\.id) == ["m2"])
    }

    @Test func aThreadWhoseKeyHasNotArrivedKeepsItsFileAndIsNotCalledDeleted() throws {
        let (mac, phone) = replicas("reproject-nokey")
        try phone.say("sealed on the phone", in: "th-p", turn: "p1")
        try Relay.deliver(Relay.records(of: phone), to: mac)
        // No key on the Mac: nothing to show, nothing to delete, nothing
        // to forget — an unreadable thread is not a deleted one.
        #expect(mac.conversations.deletedThreads().isEmpty)
        try mac.conversations.reproject(threads: ["th-p"])
        #expect(mac.store.load(id: "th-p") == nil)
        #expect(mac.projector.unreadableThreads() == ["th-p"])
        // The key arrives later (the courier); a re-projection shows it.
        try Relay.handKey(for: "th-p", from: phone, to: mac)
        try mac.conversations.reproject(threads: ["th-p"])
        #expect(mac.store.load(id: "th-p")?.turns.map(\.text) == ["sealed on the phone"])
    }
}
