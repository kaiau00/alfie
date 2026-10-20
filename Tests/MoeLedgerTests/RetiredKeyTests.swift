import Foundation
import Testing
import CryptoKit
@testable import MoeLedger

/// CLOUD-PLAN §15.1 — the joiner's memory key, storage half.
///
/// Two Macs that each ran Moe free minted their own `moe:memory`, and both
/// were right to: §13.2 refuses a mint only when the keyring looks *lost* and
/// a peer could deliver it, and a free Mac has a healthy keyring and no peers.
/// When the second joins the first's tenant the tenant's key is offered and
/// `KeyCourier.collect` declines it, because `has(thread:)` is true — correct
/// for a conversation, whose key nobody else can have minted, and wrong for
/// the one id two devices can both mint honestly. What one side then seals,
/// the other opens as `nil`: not lost, **unreadable**, and silent.
///
/// These pin the keyring half — keeping the displaced key openable. The
/// courier calling `adopt`, and the readers trying every key, follow.
@Suite struct RetiredKeyTests {

    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retired-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("thread-keys.json")
    }

    private let memory = ThreadKeyring.memoryKeyID

    /// A key whose position in `adopt`'s total order is known.
    ///
    /// These tests were first written with `SymmetricKey(size: .bits256)` on
    /// both sides, which made every one of them a coin flip the moment the
    /// tie-break existed — they passed while `adopt` was caller-wins and went
    /// flaky the instant it stopped being. Mutating the order to `>` is what
    /// exposed it, which is the argument for mutating a rule as well as
    /// deleting it: a guard can be *wrong* as well as absent.
    private func key(_ lead: UInt8) -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = lead
        return SymmetricKey(data: Data(bytes))
    }
    /// Wins against `high` under the documented order (smaller wins).
    private var low: SymmetricKey { key(0x01) }
    private var high: SymmetricKey { key(0xF0) }

    /// The whole point: what this Mac sealed before it joined stays readable.
    @Test func adoptingTheTenantsKeyKeepsTheOldOneOpenable() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        let mine = high
        try keyring.install(mine, for: memory)

        let tenants = low          // wins the order, so it is adopted
        #expect(try keyring.adopt(tenants, for: memory))

        // Sealing uses the tenant's key from now on.
        #expect(keyring.key(for: memory) == tenants)
        // Opening still reaches what this Mac wrote while it was free.
        let opening = keyring.openingKeys(for: memory)
        #expect(opening.first == tenants, "the current key must be tried first")
        #expect(opening.contains(mine), "the pre-upgrade key was dropped — memory is unreadable")
        #expect(opening.count == 2)
    }

    /// The safety property, and the reason `openingKeys` is a separate call
    /// from `key(for:)`: a retired key must never seal anything, or new
    /// records go beyond the reach of every other device in the tenant.
    @Test func aRetiredKeyIsNeverTheOneSealingUses() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        let mine = high
        try keyring.install(mine, for: memory)
        let tenants = low
        try keyring.adopt(tenants, for: memory)

        #expect(keyring.key(for: memory) != mine)
        // And a reload from disk agrees — the split has to survive the file.
        let reloaded = ThreadKeyring(url: url) { _ in }
        #expect(reloaded.key(for: memory) == tenants)
        #expect(reloaded.openingKeys(for: memory).contains(mine))
    }

    @Test func retiredKeysSurviveAReloadAndOtherWrites() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        let mine = high
        try keyring.install(mine, for: memory)
        try keyring.adopt(low, for: memory)

        // An ordinary mint by anybody must not disturb the history.
        _ = try ThreadKeyring(url: url) { _ in }.key(creatingFor: "a-conversation")
        #expect(ThreadKeyring(url: url) { _ in }.openingKeys(for: memory).contains(mine))
    }

    /// Re-delivery is the normal case — the courier ships every key on every
    /// full run — so it must not fill the file with copies of one key.
    @Test func adoptingTheSameKeyTwiceRetiresNothingExtra() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        try keyring.install(high, for: memory)
        let tenants = low
        try keyring.adopt(tenants, for: memory)
        try keyring.adopt(tenants, for: memory)
        try keyring.adopt(tenants, for: memory)
        #expect(keyring.retiredCount(for: memory) == 1)
    }

    /// An ordinary mint must not accumulate history. Only `adopt` retires.
    @Test func anOrdinaryInstallDoesNotRetireAnything() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        _ = try keyring.key(creatingFor: "a-conversation")
        try keyring.install(SymmetricKey(size: .bits256), for: "a-conversation")
        #expect(keyring.retiredCount(for: "a-conversation") == 0)
        #expect(keyring.openingKeys(for: "a-conversation").count == 1)
    }

    /// Nobody else can have minted a conversation's key, so a second one
    /// arriving is a fact to fail on rather than absorb.
    @Test func adoptRefusesAThreadThatIsNotReserved() throws {
        let keyring = ThreadKeyring(url: scratch()) { _ in }
        _ = try keyring.key(creatingFor: "a-conversation")
        #expect(throws: ThreadKeyringError.self) {
            _ = try keyring.adopt(self.low, for: "a-conversation")
        }
    }

    /// The other half of the order, which nothing pinned until the mutation
    /// testing asked for it: a key that LOSES is refused, and refusing must
    /// change nothing at all — not the current key, not the history.
    @Test func aKeyThatLosesTheOrderIsRefusedAndChangesNothing() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        try keyring.install(low, for: memory)
        #expect(try keyring.adopt(high, for: memory) == false)
        #expect(keyring.key(for: memory) == low)
        #expect(keyring.retiredCount(for: memory) == 0, "a refused adopt still retired something")
    }

    /// This was first written the other way round — asserting that destroying
    /// the thread took its history with it — and it failed, which is the
    /// reason it is worth keeping as a test of the real rule rather than of
    /// the one I assumed.
    ///
    /// A reserved id cannot be destroyed at all: `destroy` returns early for
    /// anything under `moe:` (§13.2, §18.9), because a memory key is not a
    /// conversation somebody can delete. So the only ids that can have a
    /// retired key are exactly the ids no removal path reaches, and the
    /// history is permanent by construction.
    ///
    /// `commitLocked` still clears a thread's history when it is removed. That
    /// is unreachable today and deliberately kept: it is the correct rule if a
    /// reserved id ever becomes destroyable, and a destroy that left a retired
    /// key behind would keep readable exactly what a person asked to be gone.
    @Test func aReservedThreadCannotBeDestroyedSoItsHistoryIsPermanent() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        let mine = high
        try keyring.install(mine, for: memory)
        try keyring.adopt(low, for: memory)
        #expect(keyring.retiredCount(for: memory) == 1)

        try keyring.destroy(thread: memory)   // a no-op, by design
        #expect(keyring.openingKeys(for: memory).contains(mine))
        #expect(ThreadKeyring(url: url) { _ in }.retiredCount(for: memory) == 1)
    }

    /// This replaces a test that COULD NOT FAIL, and the replacement is the
    /// interesting part.
    ///
    /// The original minted an ordinary conversation key, forgot it, and
    /// asserted the retired count was zero — but `adopt` refuses a
    /// non-reserved id, so that thread could never have had a nonzero count.
    /// The assertion was true before the code under test ran and stayed true
    /// with that code deleted: a reviewer's mutation of the removal guard
    /// killed nothing in the whole 1466-test suite. It read as coverage and
    /// was decoration.
    ///
    /// The reachable version plants the history on disk, which is the only way
    /// to get a removable thread to have any, and then removes it.
    @Test func removingAThreadClearsHistoryItActuallyHad() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        _ = try keyring.key(creatingFor: "a-conversation")
        var body = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        body["retired"] = ["a-conversation": [Data(repeating: 9, count: 32).base64EncodedString()]]
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        #expect(ThreadKeyring(url: url) { _ in }.retiredCount(for: "a-conversation") == 1,
                "the fixture did not take, so the rest of this proves nothing")

        _ = try ThreadKeyring(url: url) { _ in }.forget(threads: ["a-conversation"])

        let reloaded = ThreadKeyring(url: url) { _ in }
        #expect(reloaded.openingKeys(for: "a-conversation").isEmpty)
        #expect(reloaded.retiredCount(for: "a-conversation") == 0,
                "a retired key outlived the removal, so what was deleted is still readable")
    }

    /// §15.1's retirement is only safe where something still READS under the
    /// displaced key, and `moe:connections`'s readers ask for one key. A
    /// prefix test on `moe:` let `adopt` retire that one too, which by
    /// 664712f's own words would freeze the connection at whatever is on disk.
    @Test func adoptRefusesAReservedIdWhoseReadersCannotUseRetiredKeys() throws {
        let keyring = ThreadKeyring(url: scratch()) { _ in }
        try keyring.install(high, for: "moe:connections")
        #expect(throws: ThreadKeyringError.self) {
            _ = try keyring.adopt(self.low, for: "moe:connections")
        }
        #expect(keyring.key(for: "moe:connections") == high, "the refusal must change nothing")
        #expect(keyring.retiredCount(for: "moe:connections") == 0)
    }

    /// A retired entry this build cannot decode must survive a write.
    ///
    /// Found by probing rather than by reading, and it is `bc7349a`'s bug one
    /// level down: that commit made an unknown FIELD survive, and this build
    /// then deleted unknown CONTENTS of a field it knew. `read` drops a
    /// retired entry it cannot decode — a later build's encoding, a longer
    /// key — and writing only what was parsed removed it for good. §8's
    /// promise is about a newer version's records surviving an older reader,
    /// and a field whose contents are silently dropped keeps the letter of it
    /// while breaking the whole point.
    @Test func aRetiredEntryThisBuildCannotDecodeSurvivesAnOrdinaryWrite() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        _ = try keyring.key(creatingFor: "a-conversation")
        var body = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        body["retired"] = ["moe:memory": ["a-future-encoding-that-is-not-32-bytes"]]
        try JSONSerialization.data(withJSONObject: body).write(to: url)

        _ = try ThreadKeyring(url: url) { _ in }.key(creatingFor: "another")

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let kept = after["retired"] as? [String: Any]
        #expect(kept?["moe:memory"] != nil,
                "an entry this build could not decode was deleted by an ordinary mint")
        // And this build still reads it as no history, rather than as a
        // broken keyring — the two halves have to hold together.
        #expect(ThreadKeyring(url: url) { _ in }.retiredCount(for: memory) == 0)
    }

    /// The other half of that carry-across: it must not resurrect history a
    /// removal cleared. A retired key outliving a destroy would keep readable
    /// exactly what somebody asked to be gone.
    @Test func carryingAcrossHistoryDoesNotUndoARemoval() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        _ = try keyring.key(creatingFor: "a-conversation")
        var body = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        body["retired"] = ["a-conversation": ["a-future-encoding-that-is-not-32-bytes"]]
        try JSONSerialization.data(withJSONObject: body).write(to: url)

        _ = try ThreadKeyring(url: url) { _ in }.forget(threads: ["a-conversation"])

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let kept = (after["retired"] as? [String: Any]) ?? [:]
        #expect(kept["a-conversation"] == nil, "a removal left the thread's history behind")
    }

    /// Every keyring written before §15.1 has no `retired` field at all, and
    /// must read as "none" rather than as unreadable.
    @Test func aKeyringWithNoRetiredFieldIsOrdinary() throws {
        let url = scratch()
        _ = try ThreadKeyring(url: url) { _ in }.key(creatingFor: "a-conversation")
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(body["retired"] == nil, "a keyring with no history should not carry the field")

        let reloaded = ThreadKeyring(url: url) { _ in }
        #expect(reloaded.retiredCount(for: "a-conversation") == 0)
        #expect(reloaded.openingKeys(for: "a-conversation").count == 1)
    }

    /// A `retired` written by a newer build in a shape this one cannot parse
    /// is "no history", never "this keyring is unreadable" — the file still
    /// has to open every conversation it always did.
    @Test func aMalformedRetiredFieldDoesNotStrandTheKeyring() throws {
        let url = scratch()
        let keyring = ThreadKeyring(url: url) { _ in }
        let key = try keyring.key(creatingFor: "a-conversation")
        var body = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        body["retired"] = "a shape from the future"
        try JSONSerialization.data(withJSONObject: body).write(to: url)

        let reloaded = ThreadKeyring(url: url) { _ in }
        #expect(reloaded.key(for: "a-conversation") == key)
        #expect(reloaded.retiredCount(for: "a-conversation") == 0)
    }
}

/// The convergence half of §15.1, at the level it can actually be run.
///
/// The courier wiring lives in `MoeCloud`, whose suite needs a Postgres that
/// does not exist on this machine — so `UpgradeLifecycleTests` covers the
/// integration and is **unrun locally**. The property that makes the whole
/// thing correct is not in the courier though: it is the total order inside
/// `adopt`, and that is pure. So it is exercised here, where it runs.
///
/// What is being simulated: every device ships every key it holds to every
/// peer on a full courier run, so both sides offer and both sides decide.
@Suite struct KeyConvergenceTests {

    private func scratch(_ tag: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("converge-" + tag + "-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("thread-keys.json")
    }

    private let memory = ThreadKeyring.memoryKeyID

    /// One exchange: each side offers what it currently holds to the other.
    private func exchange(_ a: ThreadKeyring, _ b: ThreadKeyring) throws {
        let fromA = a.key(for: memory)
        let fromB = b.key(for: memory)
        if let fromA { try b.adopt(fromA, for: memory) }
        if let fromB { try a.adopt(fromB, for: memory) }
    }

    @Test func twoFreeMacsConvergeOnOneKeyAndStayThere() throws {
        let a = ThreadKeyring(url: scratch("a")) { _ in }
        let b = ThreadKeyring(url: scratch("b")) { _ in }
        let ka = try #require(try a.memoryKey(peerBook: nil))
        let kb = try #require(try b.memoryKey(peerBook: nil))
        #expect(ka != kb)

        try exchange(a, b)
        let settled = try #require(a.key(for: memory))
        #expect(b.key(for: memory) == settled, "one exchange did not converge")
        #expect(settled == ka || settled == kb, "the winner is one of the two minted keys")

        // **The ping-pong check.** A caller-wins rule converges on nothing:
        // A takes B's, B takes A's, and the next round undoes both, for ever,
        // with every record in between sealed under whichever key that minute
        // produced. Ten rounds is far past where that would show.
        for _ in 0..<10 { try exchange(a, b) }
        #expect(a.key(for: memory) == settled, "A's key moved — the two are swapping")
        #expect(b.key(for: memory) == settled, "B's key moved — the two are swapping")
    }

    /// Convergence is worth nothing if it costs the loser its own past.
    @Test func theDisplacedSideKeepsItsOwnPastReadable() throws {
        let a = ThreadKeyring(url: scratch("a")) { _ in }
        let b = ThreadKeyring(url: scratch("b")) { _ in }
        let ka = try #require(try a.memoryKey(peerBook: nil))
        let kb = try #require(try b.memoryKey(peerBook: nil))
        let aPast = try ThreadCrypto.seal("A wrote this while free", with: ka)
        let bPast = try ThreadCrypto.seal("B wrote this while free", with: kb)

        try exchange(a, b)

        func opens(_ ring: ThreadKeyring, _ sealed: String) -> Bool {
            ring.openingKeys(for: memory).contains { ThreadCrypto.open(sealed, with: $0) != nil }
        }
        #expect(opens(a, aPast), "A lost its own pre-upgrade memory")
        #expect(opens(b, bPast), "B lost its own pre-upgrade memory")
    }

    /// Order of arrival must not change the outcome, or two Macs that sync in
    /// a different order end up disagreeing.
    @Test func theWinnerDoesNotDependOnWhoOffersFirst() throws {
        for _ in 0..<20 {
            let a = ThreadKeyring(url: scratch("a")) { _ in }
            let b = ThreadKeyring(url: scratch("b")) { _ in }
            let ka = try #require(try a.memoryKey(peerBook: nil))
            let kb = try #require(try b.memoryKey(peerBook: nil))
            // A hears first.
            try a.adopt(kb, for: memory)
            try b.adopt(ka, for: memory)
            let first = a.key(for: memory)
            #expect(first == b.key(for: memory))

            // The same two keys, offered the other way round.
            let c = ThreadKeyring(url: scratch("c")) { _ in }
            let d = ThreadKeyring(url: scratch("d")) { _ in }
            try c.install(ka, for: memory)
            try d.install(kb, for: memory)
            try d.adopt(ka, for: memory)
            try c.adopt(kb, for: memory)
            #expect(c.key(for: memory) == first, "the winner depended on the order")
            #expect(d.key(for: memory) == first)
        }
    }

    /// A third Mac joining later must land on the same key as the other two,
    /// whichever of them it happens to hear from.
    @Test func aThirdMacConvergesOnWhateverTheOthersSettledOn() throws {
        let a = ThreadKeyring(url: scratch("a")) { _ in }
        let b = ThreadKeyring(url: scratch("b")) { _ in }
        _ = try a.memoryKey(peerBook: nil)
        _ = try b.memoryKey(peerBook: nil)
        try exchange(a, b)
        let settled = try #require(a.key(for: memory))

        let c = ThreadKeyring(url: scratch("c")) { _ in }
        _ = try c.memoryKey(peerBook: nil)
        try exchange(c, a)
        try exchange(c, b)
        try exchange(a, b)
        #expect(c.key(for: memory) == settled || a.key(for: memory) == c.key(for: memory),
                "three Macs did not agree")
        // And once more, everything is still.
        let before = (a.key(for: memory), b.key(for: memory), c.key(for: memory))
        try exchange(a, b); try exchange(b, c); try exchange(a, c)
        #expect((a.key(for: memory), b.key(for: memory), c.key(for: memory)) == before)
    }
}
