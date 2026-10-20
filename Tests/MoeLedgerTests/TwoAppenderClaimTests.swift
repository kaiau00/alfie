import Foundation
import Testing
import MoeChat
@testable import MoeLedger

/// The claim half of §3.1, which slice two could not reach.
///
/// §13.2 listed five rules and could exercise three. The two it could not
/// were the two with the most judgement in them and the least evidence behind
/// them — *concurrent claims, same source* and *concurrent claims, different
/// sources* — because nothing wrote a `claim` record and nothing projected
/// one. Both now happen (`Sources/MoeLedger/Claims.swift`, and the
/// `claimstore` Hermes plugin), so this file is what §13.2 was owed.
///
/// It follows `TwoAppenderTests` exactly: the same `Appender`, the same
/// `Relay`, the same fake clocks, no transport and no network. What a wire
/// would add is latency, partial delivery, duplication and reordering, and
/// those are things a test wants to *say* rather than wait for.
///
/// **What "concurrent" means here, and why it is stated rather than assumed.**
/// Two claims are concurrent when neither names the other, directly or
/// transitively, in `after` or `prev`. That is decided by the records and by
/// nothing else — never by `seq`, which two runtimes over one `~/.moe` fork
/// (§13.5), and never by `at`, which is two machines' two clocks (§1.5). Every
/// test below that says "neither side had heard" is enforced by *not* handing
/// that side the other's records before it writes, and every test that says
/// "having heard" hands them over first.
struct TwoAppenderClaimTests {

    private let sunday = Date(timeIntervalSince1970: 1_756_000_000)

    /// The Mac and the cloud: two ledger directories with a relay between.
    /// A shared directory cannot express "neither side had heard", because
    /// both sides see every byte the instant it is written.
    private func replicas(_ label: String) -> (mac: Appender, cloud: Appender) {
        let root = scratchRoot(label)
        let mac = Appender.make(name: "mac-9f3c", root: root.appendingPathComponent("mac"),
                                ledgerDirectory: root.appendingPathComponent("mac/ledger"),
                                clock: FakeClock(sunday))
        let cloud = Appender.make(name: "cloud-w7", root: root.appendingPathComponent("cloud"),
                                  ledgerDirectory: root.appendingPathComponent("cloud/ledger"),
                                  clock: FakeClock(sunday))
        return (mac, cloud)
    }

    // MARK: - Rule 1: the same fact, learned twice

    /// §3.1: "Two devices that learn the same fact … produce the same id and
    /// the second is dropped. This is not conflict resolution; it is why most
    /// apparent conflicts never exist."
    ///
    /// Note what is and is not the same. The two *records* are different —
    /// different device, different `seq`, different clock, so different record
    /// ids, and both are kept forever. The two *claims* are one claim, because
    /// the content address is a function of the words alone. That is the whole
    /// mechanism, and it needs no merge step, no model and no coordination.
    @Test func twoDevicesLearningTheSameFactConvergeWithNoMergeStep() throws {
        let (mac, cloud) = replicas("claims-converge")
        mac.clock.advance(60)
        try mac.learn("Naomi is my daughter", source: "imessage")
        cloud.clock.advance(120)
        try cloud.learn("Naomi   is  my daughter", source: "imessage")

        // Neither has heard the other yet; both hold one claim.
        #expect(mac.memory().texts == ["Naomi is my daughter"])
        #expect(cloud.memory().texts == ["Naomi   is  my daughter"])

        try Relay.sync(mac, cloud)

        #expect(mac.claims.records(target: "memory").count == 2, "both records are kept")
        #expect(mac.memory().live.count == 1, "and they are one claim")
        #expect(mac.memory().live[0].id == Claim.id(target: "memory", text: "Naomi is my daughter"))
        #expect(mac.memory().texts == cloud.memory().texts)
        #expect(mac.memory().disagreements.isEmpty, "one fact is not a disagreement")
        #expect(Convergence.between(mac, cloud) == [])
    }

    // MARK: - Rule 4: concurrent claims, same source, same topic key

    /// §3.1: "one source producing two different statements about one topic is
    /// a source that changed its mind, and the newer reading of the same
    /// source is the better one … Both records stay in the ledger; only the
    /// projection prefers the newer."
    ///
    /// Both sides crawl the same Gmail account while neither can see the
    /// other. They read the same topic differently. After they meet, both must
    /// show one answer, and it must be the *same* one answer — a rule that
    /// picks a winner deterministically on one machine and not on the other is
    /// not a rule, it is a coin toss with extra steps.
    @Test func concurrentClaimsFromOneSourceOnOneTopicResolveToOneReading() throws {
        let (mac, cloud) = replicas("claims-lww")
        mac.clock.advance(60)
        try mac.learn("Izzy works at Kaplan", key: "job", source: "gmail")
        cloud.clock.advance(120)
        try cloud.learn("Izzy works at Anthropic", key: "job", source: "gmail")

        try Relay.sync(mac, cloud)

        for side in [mac, cloud] {
            let memory = side.memory()
            #expect(memory.texts == ["Izzy works at Anthropic"],
                    "\(side.name) kept the wrong reading")
            #expect(memory.superseded.map(\.text) == ["Izzy works at Kaplan"],
                    "\(side.name) lost sight of the reading it set aside")
            #expect(memory.disagreements.isEmpty, "one source does not disagree with itself")
            #expect(side.claims.records(target: "memory").count == 2,
                    "\(side.name) dropped a record — the ledger is not opinionated (§3.2)")
        }
    }

    /// The same case with the clocks the wrong way round.
    ///
    /// This is the one that has to be looked at squarely. §3.1 says the
    /// *newer* reading wins; §1.5 says `at` "never decides who wins — it only
    /// orders records already known to be concurrent". For two concurrent
    /// claims of one source on one topic, "newer" and "the thing `at` decides"
    /// are the same thing, and there is no third signal: causality says
    /// nothing (they are concurrent, by construction) and `seq` is two
    /// different chains.
    ///
    /// So the rule as implemented is **last in ledger order wins**, and ledger
    /// order breaks concurrency with `at`, then device, then `seq`. What that
    /// buys, and what this test pins, is the property that actually matters:
    /// *both sides pick the same winner*, whichever machine's clock was ahead
    /// and whichever machine is asked. What it costs is that a Mac whose clock
    /// is an hour fast wins an argument it should have lost. See §14.2.
    @Test func lastWriteWinsIsDecidedByLedgerOrderAndBothSidesAgree() throws {
        let (mac, cloud) = replicas("claims-lww-clocks")
        // The cloud writes first in real time; the Mac's clock is ahead.
        cloud.clock.advance(60)
        try cloud.learn("Izzy works at Anthropic", key: "job", source: "gmail")
        mac.clock.advance(3600)
        try mac.learn("Izzy works at Kaplan", key: "job", source: "gmail")

        try Relay.sync(mac, cloud)

        #expect(mac.memory().texts == ["Izzy works at Kaplan"])
        #expect(cloud.memory().texts == mac.memory().texts,
                "the two sides picked different winners — this is the falsifier")
        // And a reader that has never seen either side's cache agrees.
        let cold = ClaimLedger(ledger: Ledger(directory: mac.ledger.directory, device: "cold"))
        #expect(cold.resolve(target: "memory").texts == mac.memory().texts)
    }

    // MARK: - Rule 5: concurrent claims, different sources, same topic key

    /// §3.1: "The genuine disagreement, and the one case that gets a model …
    /// with both retained and the question routed to `questions.md` if the
    /// model is unreachable."
    ///
    /// The assertion is deliberately *not* that some resolution happened. It
    /// is that neither reading was dropped and that the disagreement is named,
    /// on both sides, with the same two sources. Escalating is the behaviour;
    /// picking is what must not happen.
    @Test func concurrentClaimsFromDifferentSourcesEscalateRatherThanOneSideWinning() throws {
        let (mac, cloud) = replicas("claims-escalate")
        mac.clock.advance(60)
        try mac.learn("Izzy works at Kaplan", key: "job", source: "imessage")
        cloud.clock.advance(120)
        try cloud.learn("Izzy works at Anthropic", key: "job", source: "gmail")

        try Relay.sync(mac, cloud)

        for side in [mac, cloud] {
            let memory = side.memory()
            #expect(Set(memory.texts) == ["Izzy works at Kaplan", "Izzy works at Anthropic"],
                    "\(side.name) dropped a reading instead of escalating")
            #expect(memory.superseded.isEmpty, "nothing was superseded; they are different sources")
            #expect(memory.disagreements.count == 1, "\(side.name) did not raise the disagreement")
            let disagreement = try #require(memory.disagreements.first)
            #expect(disagreement.key == "job")
            #expect(disagreement.sources.sorted() == ["gmail", "imessage"])
            #expect(disagreement.readings.count == 2)
        }
        // Both sides describe the same disagreement in the same words, which
        // is what makes it one question to a person rather than two.
        #expect(mac.memory().disagreements == cloud.memory().disagreements)
    }

    /// The two rules compose the way `merge.py` composes them: each source is
    /// collapsed to its own newest reading first, and what is left over is
    /// the disagreement. Three readings, two sources, one question.
    @Test func eachSourceIsCollapsedBeforeTheSourcesAreCompared() throws {
        let (mac, cloud) = replicas("claims-compose")
        mac.clock.advance(60)
        try mac.learn("Izzy works at Kaplan", key: "job", source: "gmail")
        mac.clock.advance(60)
        try mac.learn("Izzy works at Anthropic", key: "job", source: "gmail")
        cloud.clock.advance(200)
        try cloud.learn("Izzy works at Pulse", key: "job", source: "imessage")

        try Relay.sync(mac, cloud)

        for side in [mac, cloud] {
            let memory = side.memory()
            #expect(memory.texts == ["Izzy works at Anthropic", "Izzy works at Pulse"])
            #expect(memory.superseded.map(\.text) == ["Izzy works at Kaplan"])
            #expect(memory.disagreements.count == 1)
            #expect(memory.disagreements.first?.sources.sorted() == ["gmail", "imessage"])
        }
    }

    /// A claim with no topic key can only ever contend with itself.
    ///
    /// This is what keeps the ordinary case cheap and safe: most of what a
    /// crawl learns is not an answer to a question anything else is also
    /// answering, and giving every such claim its own key by default means
    /// two unrelated facts can never be read as a disagreement.
    @Test func claimsWithNoTopicKeyNeverContend() throws {
        let (mac, cloud) = replicas("claims-no-key")
        mac.clock.advance(60)
        try mac.learn("deploys run on Fridays", source: "gmail")
        cloud.clock.advance(120)
        try cloud.learn("the office is in Frankfurt", source: "imessage")

        try Relay.sync(mac, cloud)
        for side in [mac, cloud] {
            #expect(side.memory().texts.count == 2)
            #expect(side.memory().disagreements.isEmpty)
            #expect(side.memory().superseded.isEmpty)
        }
    }

    // MARK: - Retraction, and the half §13.2 could not reach

    /// §3.1's tombstone amendment, the crawl half: "A crawl-sourced assert
    /// after a tombstone still does not [revive]."
    ///
    /// The person deletes a fact on their phone on Tuesday. The Mac's Gmail
    /// crawl re-derives it on Wednesday, having seen the deletion. It must not
    /// come back — that is what a tombstone is *for*.
    @Test func aCrawlDoesNotBringBackWhatThePersonDeleted() throws {
        let (mac, cloud) = replicas("claims-crawl-revive")
        mac.clock.advance(60)
        try mac.learn("I work at Kaplan", source: "gmail")
        try Relay.sync(mac, cloud)

        cloud.clock.advance(120)
        let tombstone = try #require(try cloud.forget("I work at Kaplan", source: "user"))
        try Relay.sync(mac, cloud)
        #expect(mac.memory().texts.isEmpty, "the deletion did not reach the Mac")

        // The crawl runs again on the Mac, and it has seen the deletion.
        mac.clock.advance(600)
        try mac.learn("I work at Kaplan", source: "gmail", after: [tombstone.id])
        try Relay.sync(mac, cloud)

        for side in [mac, cloud] {
            #expect(side.memory().texts.isEmpty,
                    "\(side.name) let a crawl undo a person's deletion")
            #expect(side.claims.records(target: "memory").count == 3,
                    "\(side.name) dropped a record; the ledger keeps all three (§3.2)")
        }
    }

    /// The other half of the same amendment, and the one §13.2 recorded as
    /// **not exercised**: "a `source=user` assert that is causally after a
    /// tombstone revives the claim."
    ///
    /// This is the case §3.1 was written for by name — the person deletes a
    /// claim on their phone on Tuesday and tells the Mac "remember I work at
    /// Kaplan" on Wednesday — and an unconditional tombstone would eat it.
    @Test func thePersonSayingItAgainAfterADeletionBringsItBack() throws {
        let (mac, cloud) = replicas("claims-user-revive")
        mac.clock.advance(60)
        try mac.learn("I work at Kaplan", source: "imessage")
        try Relay.sync(mac, cloud)

        cloud.clock.advance(120)
        let tombstone = try #require(try cloud.forget("I work at Kaplan", source: "user"))
        try Relay.sync(mac, cloud)
        #expect(mac.memory().texts.isEmpty)

        mac.clock.advance(600)
        try mac.learn("I work at Kaplan", source: Claim.userSource, after: [tombstone.id])
        try Relay.sync(mac, cloud)

        for side in [mac, cloud] {
            #expect(side.memory().texts == ["I work at Kaplan"],
                    "\(side.name) ate what the person said on Wednesday")
            #expect(side.memory().live.first?.source == Claim.userSource)
        }
    }

    /// And the case that makes the amendment *causal* rather than positional.
    ///
    /// A revival is only a revival of the tombstone it can see. Here the Mac
    /// deletes and re-states a fact locally — a perfectly good `user` revival
    /// of *its own* tombstone — while the phone, which has heard neither,
    /// deletes the same fact. The Mac's re-statement is concurrent with the
    /// phone's tombstone, so it is suppressed, even though its source is the
    /// person and even though its clock is two hours ahead. If this were
    /// decided positionally, or on `at`, a device that had simply been asleep
    /// would undo a deletion by accident, and which machine's clock was ahead
    /// would decide whether a person's deletion stuck. That is the claim-side
    /// twin of §13.1's second finding, and the mutation that makes the check
    /// positional is caught here and nowhere else.
    @Test func aRepetitionThatNeverHeardAboutTheDeletionDoesNotUndoIt() throws {
        let (mac, cloud) = replicas("claims-concurrent-revive")
        mac.clock.advance(60)
        try mac.learn("I work at Kaplan", source: "imessage")
        try Relay.sync(mac, cloud)

        // Tuesday, on the phone: deleted. The Mac is not told.
        cloud.clock.advance(120)
        try cloud.forget("I work at Kaplan", source: "user")

        // On the Mac, hours later by its own clock: the person takes it back
        // and then says it again. Both records name the Mac's own tombstone,
        // and neither has ever seen the phone's.
        mac.clock.advance(3600)
        let mine = try #require(try mac.forget("I work at Kaplan", source: Claim.userSource))
        mac.clock.advance(3600)
        try mac.learn("I work at Kaplan", source: Claim.userSource, after: [mine.id])
        #expect(mac.memory().texts == ["I work at Kaplan"],
                "on its own, the Mac's revival of its own tombstone is valid")

        try Relay.sync(mac, cloud)

        for side in [mac, cloud] {
            #expect(side.memory().texts.isEmpty,
                    "\(side.name) revived a deleted claim on a clock rather than on causality")
        }
        // Both tombstones and both asserts are still there to be explained.
        #expect(mac.claims.records(target: "memory").count == 4)
    }

    // MARK: - Nothing but the person revives, and nothing is dropped for it

    /// The one this design must not get wrong.
    ///
    /// A person deletes a fact about themselves. Later the assistant, on its
    /// own initiative, writes the same words through the memory tool —
    /// `assistant_tool` is Hermes's *default* `write_origin`, and
    /// `background_review` and `side_question` are the only others; none of
    /// them means anybody asked. An earlier version of this rule accepted all
    /// three as "the person", on the reading that a memory-tool write is
    /// §3.1's own worked example ("tells the Mac 'remember I work at Kaplan'
    /// on Wednesday"). It is not, and the cost of being wrong is a person's
    /// deletion quietly undone by the software that was told to make it.
    @Test func theAssistantCannotRestoreWhatThePersonDeleted() throws {
        let (mac, cloud) = replicas("claims-no-assistant-revive")
        mac.clock.advance(60)
        try mac.learn("I work at Kaplan", source: "imessage")
        try Relay.sync(mac, cloud)
        cloud.clock.advance(120)
        let tombstone = try #require(try cloud.forget("I work at Kaplan", source: "user"))
        try Relay.sync(mac, cloud)

        for origin in ["hermes:assistant_tool", "hermes:background_review",
                       "hermes:side_question"] {
            mac.clock.advance(600)
            try mac.learn("I work at Kaplan", source: origin, after: [tombstone.id])
            #expect(mac.memory().texts.isEmpty,
                    "\(origin) restored a fact the person deleted, unasked")
        }
        try Relay.sync(mac, cloud)
        for side in [mac, cloud] {
            #expect(side.memory().texts.isEmpty)
            // Not dropped in silence, either: one deleted fact, one question.
            #expect(side.memory().pendingRevivals.count == 1,
                    "\(side.name) discarded the restatements rather than asking")
            #expect(side.memory().pendingRevivals.first?.source == "hermes:side_question",
                    "the question is about the most recent restatement")
            #expect(side.claims.records(target: "memory").count == 5,
                    "\(side.name) dropped a record; all five are kept (§3.2)")
        }
        #expect(mac.memory().pendingRevivals == cloud.memory().pendingRevivals,
                "the two sides would ask different questions")
    }

    /// The other half of the seam: what "yes" does.
    ///
    /// `confirmRevival` is an ordinary `user`-sourced assert, so it revives by
    /// the ordinary rule and needs no special case. The point is that a caller
    /// has to *say* the person answered, and can only honestly say it after
    /// asking. Nothing in the plugin can call this on its own.
    @Test func answeringYesTurnsAQuestionIntoAnEntry() throws {
        let (mac, cloud) = replicas("claims-confirm")
        mac.clock.advance(60)
        try mac.learn("I work at Kaplan", source: "imessage")
        try Relay.sync(mac, cloud)
        cloud.clock.advance(60)
        let tombstone = try #require(try cloud.forget("I work at Kaplan", source: "user"))
        try Relay.sync(mac, cloud)
        mac.clock.advance(600)
        try mac.learn("I work at Kaplan", source: "gmail", after: [tombstone.id])

        let question = try #require(mac.memory().pendingRevivals.first)
        #expect(mac.memory().texts.isEmpty)

        mac.clock.advance(60)
        try mac.claims.confirmRevival(question, surface: "notch")

        try Relay.sync(mac, cloud)
        for side in [mac, cloud] {
            #expect(side.memory().texts == ["I work at Kaplan"])
            #expect(side.memory().live.first?.source == "user:notch")
            #expect(side.memory().pendingRevivals.isEmpty,
                    "\(side.name) is still asking about something it now remembers")
        }
    }

    /// "No, forget it" has to land as a record too, or the question just goes
    /// away and comes back the next time anything re-states the fact.
    @Test func answeringNoIsARecordRatherThanSilence() throws {
        let (mac, cloud) = replicas("claims-decline")
        mac.clock.advance(60)
        try mac.learn("I work at Kaplan", source: "gmail")
        mac.clock.advance(60)
        let tombstone = try #require(try mac.forget("I work at Kaplan", source: "user"))
        mac.clock.advance(60)
        try mac.learn("I work at Kaplan", source: "gmail", after: [tombstone.id])
        let question = try #require(mac.memory().pendingRevivals.first)

        mac.clock.advance(60)
        try mac.claims.retract(id: question.id, source: Claim.userSource)

        #expect(mac.memory().pendingRevivals.isEmpty, "the question was not answered")
        #expect(mac.memory().texts.isEmpty)
        #expect(mac.claims.records(target: "memory").count == 4)
        try Relay.sync(mac, cloud)
        #expect(cloud.memory().pendingRevivals.isEmpty)
    }

    /// A restatement by somebody who had not heard about the deletion is not a
    /// question. There is nothing to ask them: they were not contradicting
    /// anything, they were simply behind.
    @Test func aRestatementThatNeverHeardIsNotEvenAQuestion() throws {
        let (mac, cloud) = replicas("claims-not-a-question")
        mac.clock.advance(60)
        try mac.learn("I work at Kaplan", source: "imessage")
        try Relay.sync(mac, cloud)

        cloud.clock.advance(120)
        try cloud.forget("I work at Kaplan", source: "user")
        // The Mac has not heard, and re-derives it.
        mac.clock.advance(7200)
        try mac.learn("I work at Kaplan", source: "gmail", after: [])

        try Relay.sync(mac, cloud)
        for side in [mac, cloud] {
            #expect(side.memory().texts.isEmpty)
            #expect(side.memory().pendingRevivals.isEmpty,
                    "\(side.name) asked about a restatement that had not heard")
        }
    }

    /// Only the person, stated as a property of the function rather than
    /// through a scenario — because this is the rule that diverged between the
    /// two languages once already, and a two-line function is exactly the kind
    /// that gets tested only through its callers.
    @Test func onlyThePersonCountsAsThePerson() {
        #expect(Claim.revives(source: "user"))
        #expect(Claim.revives(source: "user:notch"))
        for source in ["hermes:assistant_tool", "hermes:background_review",
                       "hermes:side_question", "gmail", "imessage", "file", "", "user-ish"] {
            #expect(!Claim.revives(source: source),
                    "\(source) must not undo a person's deletion")
        }
    }

    // MARK: - §3.2: the projection is opinionated, the ledger is not

    /// Everything above decides what the digest *shows*. Nothing above decides
    /// what is *kept*. This is that invariant, asserted directly: after a
    /// deletion, a supersession and an escalation, every record ever written
    /// is still in the ledger on both sides and can still be named.
    @Test func nothingIsEverRemovedFromTheLedgerByAnyOfThese() throws {
        let (mac, cloud) = replicas("claims-nothing-lost")
        mac.clock.advance(60)
        try mac.learn("Izzy works at Kaplan", key: "job", source: "gmail")
        cloud.clock.advance(90)
        try cloud.learn("Izzy works at Anthropic", key: "job", source: "gmail")
        cloud.clock.advance(30)
        try cloud.learn("Izzy works at Pulse", key: "job", source: "imessage")
        mac.clock.advance(120)
        try mac.learn("deploys run on Fridays", source: "gmail")
        try Relay.sync(mac, cloud)
        cloud.clock.advance(60)
        try cloud.forget("deploys run on Fridays", source: "user")
        try Relay.sync(mac, cloud)

        for side in [mac, cloud] {
            let records = side.claims.records(target: "memory")
            #expect(records.count == 5, "\(side.name) is missing a record")
            let memory = side.memory()
            // Suppressed by a tombstone, superseded by a newer reading, and
            // escalated — three different fates, one ledger.
            #expect(memory.texts.count == 2)
            #expect(memory.superseded.count == 1)
            #expect(memory.disagreements.count == 1)
            // The suppressed claim is still findable by its id, which is what
            // `moe memory why` will need.
            let deleted = Claim.id(target: "memory", text: "deploys run on Fridays")
            #expect(records.contains { $0.body["claim"]?.stringValue == deleted })
            #expect(!memory.live.contains { $0.id == deleted })
        }
        #expect(Convergence.between(mac, cloud) == [])
    }

    // MARK: - Claims must not disturb conversations

    /// §13.1's eighth finding was about "the day a `claim` names a thread":
    /// `ConversationProjector` indexes on `body["thread"]` and deletes the
    /// file of a thread that has a tombstone and nothing surviving. Claim
    /// bodies carry no `thread`, deliberately, and this is what says so — a
    /// ledger holding a conversation, a deleted conversation, and a hundred
    /// claims projects exactly the conversations it did before the claims
    /// existed.
    @Test func claimsDoNotDisturbConversations() throws {
        let (mac, cloud) = replicas("claims-and-threads")
        mac.clock.advance(60)
        try mac.say("what did we decide about Kaplan?", in: "th-kaplan", turn: "t1")
        mac.clock.advance(60)
        try mac.say("nothing yet", in: "th-kaplan", turn: "t2", role: .moe)
        mac.clock.advance(60)
        try mac.say("delete me", in: "th-gone", turn: "t3")
        try mac.conversations.delete(id: "th-gone")

        let threadsBefore = mac.projector.threads()
        let projectedBefore = mac.projector.project(thread: "th-kaplan")

        for i in 0..<100 {
            mac.clock.advance(1)
            try mac.background("imessage", "fact-\(i)", "claim number \(i)")
        }

        #expect(mac.projector.threads() == threadsBefore, "a claim invented a thread")
        #expect(mac.projector.project(thread: "th-kaplan") == projectedBefore,
                "a claim changed a conversation")
        #expect(mac.projector.isDeleted(thread: "th-gone"))
        #expect(mac.memory().texts.count == 100)

        try Relay.sync(mac, cloud)
        try Relay.handKey(for: "th-kaplan", from: mac, to: cloud)
        #expect(try Convergence.onDisk(mac, cloud) == [])
        #expect(cloud.memory().texts.count == 100)
    }

    // MARK: - Concurrency, on real threads

    /// Two appenders over one ledger directory, learning at the same moment.
    ///
    /// The shared-directory shape rather than the relay, because this is the
    /// concurrency question rather than the causality one: two writers
    /// appending while two readers are mid-parse of each other's files. The
    /// property is that nothing is lost and that both readers — and a cold
    /// third one — agree on what is live.
    @Test func concurrentLearningLosesNothingAndEverybodyAgrees() throws {
        let root = scratchRoot("claims-concurrent")
        let directory = root.appendingPathComponent("ledger")
        let clock = FakeClock(sunday)
        let one = Appender.make(name: "mac-one", root: root.appendingPathComponent("one"),
                                ledgerDirectory: directory, clock: clock, distinctInstants: true)
        let two = Appender.make(name: "mac-two", root: root.appendingPathComponent("two"),
                                ledgerDirectory: directory, clock: clock, distinctInstants: true)

        let group = DispatchGroup()
        for (index, side) in [one, two].enumerated() {
            DispatchQueue.global().async(group: group) {
                for i in 0..<40 {
                    _ = try? side.learn("\(side.name) learned fact \(i)",
                                        key: "fact-\(index)-\(i)", source: "crawl-\(index)")
                }
            }
        }
        group.wait()

        let cold = ClaimLedger(ledger: Ledger(directory: directory, device: "cold"))
        #expect(cold.resolve(target: "memory").texts.count == 80, "a concurrent write was lost")
        #expect(one.memory().texts == cold.resolve(target: "memory").texts,
                "the warm reader disagrees with a cold one")
        #expect(two.memory().texts == cold.resolve(target: "memory").texts)
        #expect(one.memory().disagreements.isEmpty)
    }

    // MARK: - The strain worth naming

    /// §3.1's last two rules are both headed "**Concurrent** claims". Read
    /// strictly, they never fire for two readings that *are* causally ordered
    /// — and rule 2 says of those only "B is later. No rule fires."
    ///
    /// Taken at its word that leaves the digest showing both "Izzy works at
    /// Kaplan" and "Izzy works at Anthropic" from one Gmail crawl, forever,
    /// with nothing raised, purely because the second crawl had seen the
    /// first. That is worse than the concurrent case, not better.
    ///
    /// This build therefore applies rules 4 and 5 to every pair of live
    /// readings of a topic, concurrent or not, which is what `merge.py` — the
    /// implementation §3.1 cites for both rules — actually does; it has no
    /// notion of concurrency at all. The strain is written up in §14.2 rather
    /// than resolved silently here, and this test is what makes the choice
    /// visible instead of implicit.
    @Test func causallyOrderedReadingsOfOneTopicAreResolvedToo() throws {
        let (mac, _) = replicas("claims-causal-key")
        mac.clock.advance(60)
        let first = try #require(try mac.learn("Izzy works at Kaplan", key: "job", source: "gmail"))
        mac.clock.advance(60)
        try mac.learn("Izzy works at Anthropic", key: "job", source: "gmail", after: [first.id])

        #expect(mac.memory().texts == ["Izzy works at Anthropic"],
                "a causally ordered pair of readings was left unresolved")
        #expect(mac.memory().superseded.map(\.text) == ["Izzy works at Kaplan"])

        // The different-source version of the same shape: escalated, not
        // silently won by whichever crawl ran second.
        let (other, _) = replicas("claims-causal-key-2")
        other.clock.advance(60)
        let a = try #require(try other.learn("lives in Berlin", key: "city", source: "gmail"))
        other.clock.advance(60)
        try other.learn("lives in Frankfurt", key: "city", source: "imessage", after: [a.id])
        #expect(other.memory().disagreements.count == 1,
                "a causally ordered disagreement was resolved by silence")
        #expect(Set(other.memory().texts) == ["lives in Berlin", "lives in Frankfurt"])
    }

    // MARK: - The three-day case, for memory

    /// §1.4's scenario, asked of memory rather than of conversation.
    ///
    /// The Mac is offline Monday to Wednesday and not idle: its learn crawl
    /// and hourly digest keep writing claims about sources the cloud has never
    /// been able to see. The cloud writes claims about sources the Mac cannot
    /// see. They overlap on exactly one topic, from two sources, and they
    /// overlap on one fact they both learned independently.
    @Test func threeDaysOfMemoryApartAndBothSidesComeBackTheSame() throws {
        let (mac, cloud) = replicas("claims-three-days")
        mac.clock.advance(3600)
        try mac.learn("Naomi is my daughter", source: "imessage")
        try Relay.sync(mac, cloud)

        for day in 1...3 {
            for hour in 0..<24 {
                mac.clock.advance(3600)
                try mac.background("digest", "hour-\(day)-\(hour)", "day \(day) hour \(hour) was quiet")
                cloud.clock.advance(3600)
                try cloud.background("gmail", "thread-\(day)-\(hour)", "unread thread \(day)-\(hour)")
            }
            // Both learn the same fact from the same place, independently.
            mac.clock.advance(60)
            try mac.learn("the standup is at 09:30", source: "calendar")
            cloud.clock.advance(60)
            try cloud.learn("the standup is at 09:30", source: "calendar")
        }
        // One genuine disagreement, from two sources, neither having heard.
        mac.clock.advance(60)
        try mac.learn("Izzy works at Kaplan", key: "job", source: "imessage")
        cloud.clock.advance(60)
        try cloud.learn("Izzy works at Anthropic", key: "job", source: "gmail")
        // And a deletion on the phone the Mac must honour.
        cloud.clock.advance(60)
        try cloud.forget("Naomi is my daughter", source: "user")

        try Relay.sync(mac, cloud)

        #expect(Convergence.between(mac, cloud) == [])
        for side in [mac, cloud] {
            #expect(side.ledger.gapsForThisDevice() == [], "\(side.name) lost a record")
            #expect(side.ledger.forkedSeqsForThisDevice() == [])
            let memory = side.memory()
            // 72 digests + 72 gmail + one standup (one claim, three records,
            // two devices) + two readings of the job topic.
            #expect(memory.texts.count == 147, "\(side.name) has \(memory.texts.count) claims")
            #expect(!memory.texts.contains("Naomi is my daughter"),
                    "\(side.name) resurrected a claim the person deleted")
            #expect(memory.texts.filter { $0 == "the standup is at 09:30" }.count == 1,
                    "\(side.name) holds one fact twice")
            #expect(memory.disagreements.count == 1)
            #expect(memory.disagreements.first?.sources.sorted() == ["gmail", "imessage"])
        }
        #expect(mac.memory().texts == cloud.memory().texts,
                "the two sides would print different memory files")
        #expect(mac.memory().disagreements == cloud.memory().disagreements)

        // A second reconciliation changes nothing — the relay is idempotent
        // because the records are content-addressed.
        let before = mac.memory().texts
        try Relay.sync(mac, cloud)
        #expect(mac.memory().texts == before)
        #expect(try Relay.deliver(Relay.records(of: cloud), to: mac) == 0)
    }
}
