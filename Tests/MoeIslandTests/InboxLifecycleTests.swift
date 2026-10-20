import Foundation
import Testing
@testable import MoeIsland

/// How a card lives and ends (docs/INBOX-QUIET.md slice 1): one card per
/// subject, closed by its source, the backlog archived once.
struct InboxLifecycleTests {

    static let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    static func input(_ text: String, at: Date = t0, offer: String = "", loops: [String] = [],
                      subject: String = "", job: String = "", kind: String = "") -> NoticeInput {
        var i = NoticeInput(text: text, at: at)
        i.offer = offer
        i.loops = loops
        i.subject = subject
        i.job = job
        i.kind = kind
        return i
    }

    /// The pure door the Conductor uses: subject first, then the same words.
    static func receive(_ i: NoticeInput, into list: inout [InboxItem]) {
        let n = NoticeMaker.make(i)
        if let at = InboxLifecycle.openCard(about: n.subject, in: list) {
            InboxLifecycle.absorb(n, into: &list[at])
        } else if let at = list.firstIndex(where: { $0.status == .open && $0.body == i.text }) {
            list[at].seen = false
        } else {
            list.insert(n, at: 0)
        }
    }

    static let none = InboxLifecycle.Sources(offerLive: { _ in nil }, openLoops: nil)

    // MARK: Subject

    @Test func theSubjectIsTheWritersElseTheSituationElseTheFirstLoop() {
        #expect(NoticeMaker.make(Self.input("a", offer: "sit_1", loops: ["x"], subject: "promise:p9")).subject == "promise:p9")
        #expect(NoticeMaker.make(Self.input("a", offer: "sit_1", loops: ["x"])).subject == "situation:sit_1")
        #expect(NoticeMaker.make(Self.input("a", loops: ["", "hanoi", "israel"])).subject == "loop:hanoi")
        #expect(NoticeMaker.make(Self.input("a")).subject == "")
        #expect(NoticeMaker.make(Self.input("a", subject: "  event:\nk1 ")).subject == "event: k1")
    }

    @Test func theSubjectSurvivesTheFileAndAnOldFileReadsWithout() throws {
        var n = NoticeMaker.make(Self.input("a", loops: ["hanoi"]))
        n.seen = true
        let e = JSONEncoder(), d = JSONDecoder()
        let back = try d.decode(InboxItem.self, from: e.encode(n))
        #expect(back.subject == "loop:hanoi")
        var obj = try #require(JSONSerialization.jsonObject(with: e.encode(n)) as? [String: Any])
        obj.removeValue(forKey: "subject")
        let old = try d.decode(InboxItem.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.subject == "")
    }

    @Test func aRewordedRepeatUpdatesTheOpenCardInPlace() {
        var list: [InboxItem] = []
        Self.receive(Self.input("Israel may be about to send more money to a fake tax investigator.",
                                offer: "sit_52d1"), into: &list)
        let id = list[0].id
        list[0].seen = true
        list[0].hidden = true
        list[0].snoozedUntil = Self.t0.addingTimeInterval(3600)
        Self.receive(Self.input("Israel is being pressured by someone posing as a Tax Authority officer.",
                                at: Self.t0.addingTimeInterval(600), offer: "sit_52d1"), into: &list)
        #expect(list.count == 1)
        #expect(list[0].id == id, "the same card, so a reading card open on it stays on it")
        #expect(list[0].body.hasPrefix("Israel is being pressured"))
        #expect(list[0].title.hasPrefix("Israel is being pressured"))
        #expect(list[0].at == Self.t0.addingTimeInterval(600), "raised back to the top")
        #expect(!list[0].seen && !list[0].hidden && list[0].snoozedUntil == nil)
    }

    @Test func aFinishedCardIsNotReopenedAndNoSubjectNeverMerges() {
        var list: [InboxItem] = []
        Self.receive(Self.input("Miriam's access is overdue.", loops: ["miriam"]), into: &list)
        InboxLifecycle.archive(&list[0], now: Self.t0, outcome: "Done")
        Self.receive(Self.input("Miriam's access is still overdue.", loops: ["miriam"]), into: &list)
        #expect(list.count == 2 && list[0].status == .open && list[1].status == .done)
        Self.receive(Self.input("One thing."), into: &list)
        Self.receive(Self.input("Another thing."), into: &list)
        #expect(list.filter { $0.subject.isEmpty }.count == 2)
        // The exact-words fallback still holds for a card with no subject.
        Self.receive(Self.input("One thing."), into: &list)
        #expect(list.filter { $0.body == "One thing." }.count == 1)
    }

    // MARK: Closed by their source

    @Test func anOfferWhoseSituationIsOverCloses() {
        var list: [InboxItem] = []
        Self.receive(Self.input("A reply is ready.", offer: "sit_live"), into: &list)
        Self.receive(Self.input("Another reply is ready.", offer: "sit_gone"), into: &list)
        Self.receive(Self.input("A third.", offer: "sit_unknown"), into: &list)
        let sources = InboxLifecycle.Sources(offerLive: { id in
            id == "sit_live" ? true : id == "sit_gone" ? false : nil
        }, openLoops: nil)
        let later = Self.t0.addingTimeInterval(InboxLifecycle.grace + 1)
        let gone = InboxLifecycle.resolved(list, now: later, sources: sources)
        #expect(gone.map(\.id) == list.filter { $0.offer == "sit_gone" }.map(\.id))
        #expect(gone.first?.outcome == "No longer current")
        // Within the grace the engine has not marked it offered yet.
        #expect(InboxLifecycle.resolved(list, now: Self.t0.addingTimeInterval(60), sources: sources).isEmpty)
    }

    @Test func aFollowUpWhoseLoopsAreAllClosedCloses() {
        var list: [InboxItem] = []
        Self.receive(Self.input("Hanoi hotel.", loops: ["hanoi", "israel-meet"]), into: &list)
        Self.receive(Self.input("Eli waits.", loops: ["eli"]), into: &list)
        Self.receive(Self.input("A plain reminder.", job: "reminder"), into: &list)
        let later = Self.t0.addingTimeInterval(InboxLifecycle.grace + 1)
        let one = InboxLifecycle.Sources(offerLive: { _ in nil }, openLoops: ["israel-meet"])
        let gone = InboxLifecycle.resolved(list, now: later, sources: one)
        #expect(gone.map(\.id) == list.filter { $0.loops == ["eli"] }.map(\.id), "one loop still open keeps it")
        #expect(gone.first?.outcome == "Settled")
        // A ledger that could not be read closes nothing.
        #expect(InboxLifecycle.resolved(list, now: later, sources: Self.none).isEmpty)
    }

    @Test func aMeetingHeadsUpClosesOnceTheMeetingHasStarted() {
        let job = InboxLifecycle.headsUpJob
        let n = NoticeMaker.make(Self.input("Andrew Wilson Follow Up Discussion starts in 9 minutes — Microsoft Teams.", job: job))
        #expect(InboxLifecycle.meetingStart(n) == Self.t0.addingTimeInterval(9 * 60))
        #expect(InboxLifecycle.resolved([n], now: Self.t0.addingTimeInterval(8 * 60), sources: Self.none).isEmpty)
        #expect(InboxLifecycle.resolved([n], now: Self.t0.addingTimeInterval(9 * 60), sources: Self.none).first?.outcome
                == "Meeting started")
        let two = NoticeMaker.make(Self.input("Standup is starting now.\nReview starts in 12 minutes.", job: job))
        #expect(InboxLifecycle.meetingStart(two) == Self.t0.addingTimeInterval(12 * 60))
        let one = NoticeMaker.make(Self.input("Dentist starts in a minute.", job: job))
        #expect(InboxLifecycle.meetingStart(one) == Self.t0.addingTimeInterval(60))
        // No time it can read: half an hour.
        let vague = NoticeMaker.make(Self.input("Something in your calendar soon.", job: job))
        #expect(InboxLifecycle.meetingStart(vague) == nil)
        #expect(InboxLifecycle.resolved([vague], now: Self.t0.addingTimeInterval(29 * 60), sources: Self.none).isEmpty)
        #expect(InboxLifecycle.resolved([vague], now: Self.t0.addingTimeInterval(30 * 60), sources: Self.none).count == 1)
        // The same words from anything else is not a heads-up.
        let other = NoticeMaker.make(Self.input("Andrew starts in 9 minutes.", job: "reminder"))
        #expect(InboxLifecycle.resolved([other], now: Self.t0.addingTimeInterval(3600), sources: Self.none).isEmpty)
    }

    // MARK: The backlog

    @Test func theBacklogKeepsOnlyRecentReadyWork() {
        let now = Self.t0
        var list: [InboxItem] = []
        Self.receive(Self.input("Insurer offer is $7,108 under valuation.", at: now.addingTimeInterval(-3600),
                                offer: "sit_ins"), into: &list)
        Self.receive(Self.input("A draft is ready.", at: now.addingTimeInterval(-20 * 3600), kind: "work"), into: &list)
        Self.receive(Self.input("Old offer.", at: now.addingTimeInterval(-50 * 3600), offer: "sit_old"), into: &list)
        Self.receive(Self.input("Marketing brief.", at: now.addingTimeInterval(-600), kind: "brief"), into: &list)
        Self.receive(Self.input("Hanoi.", at: now.addingTimeInterval(-600), loops: ["hanoi"]), into: &list)
        var done = NoticeMaker.make(Self.input("Done already.", at: now.addingTimeInterval(-600)))
        InboxLifecycle.archive(&done, now: now)
        list.append(done)
        let archived = Set(InboxLifecycle.backlog(list, now: now))
        let kept = list.filter { $0.status == .open && !archived.contains($0.id) }.map(\.body)
        #expect(Set(kept) == ["Insurer offer is $7,108 under valuation.", "A draft is ready."])
        #expect(!archived.contains(done.id), "a finished card is not archived again")
        var n = list[0]
        InboxLifecycle.archive(&n, now: now)
        #expect(n.status == .done && n.outcome == "Archived" && n.doneAt == now && n.seen)
    }

    // MARK: Last week, replayed

    /// Twenty notices shaped like 2026-09-29 → 10-06 (anonymised): the scam
    /// worry reworded four times, the hotel follow-up three times, a closed
    /// loop that kept producing, an offer that went stale, a meeting heads-up
    /// past its time, and two things that are still live. The inbox ends
    /// with one card per live subject and none for what is over.
    @Test func lastWeekReplayedEndsWithOneCardPerLiveSubject() {
        let h: TimeInterval = 3600
        let start = Self.t0
        func at(_ hours: Double) -> Date { start.addingTimeInterval(hours * h) }
        let stream: [NoticeInput] = [
            // The scam worry: one situation, reworded.
            Self.input("Israel may be about to send more money to a fake tax investigator.", at: at(0), offer: "sit_scam"),
            Self.input("Israel is being pressured by someone posing as a crypto tax officer.", at: at(5), offer: "sit_scam"),
            Self.input("Israel hasn't reported the losses to the exchange or the police yet.", at: at(20), offer: "sit_scam"),
            Self.input("Israel has lost at least $4,495 this month and is still waiting on a refund.", at: at(30), offer: "sit_scam"),
            // The hotel: one follow-up, reworded, sometimes with other loops beside it.
            Self.input("You need a replacement hotel for Hanoi before you arrive tomorrow.", at: at(1), loops: ["hanoi-hotel"]),
            Self.input("The host cancelled your Hanoi stay for Oct 6–7.", at: at(3), loops: ["hanoi-hotel", "family-meet"]),
            Self.input("Accommodation cancelled & family updates.", at: at(14), loops: ["hanoi-hotel", "scam-guide"]),
            // A loop that was closed and kept producing.
            Self.input("Shlomo's still waiting for the $1,078 transfer.", at: at(2), loops: ["cash-split"]),
            Self.input("Shlomo's at the bank and needs the transfer.", at: at(6), loops: ["cash-split"]),
            Self.input("Shlomo's asking you to send the remaining amount.", at: at(26), loops: ["cash-split"]),
            // An offer that went stale.
            Self.input("Seven pre-charts you promised for today's visits are due.", at: at(4), offer: "sit_precharts"),
            Self.input("The pre-charts for tomorrow can still get in.", at: at(8), offer: "sit_precharts"),
            // Meeting heads-ups, long past.
            Self.input("Weekly Follow Up Discussion starts in 9 minutes — Teams.", at: at(10), job: InboxLifecycle.headsUpJob),
            Self.input("Design review is starting now.", at: at(22), job: InboxLifecycle.headsUpJob),
            // Live: the insurer offer, and the RSVP follow-up.
            Self.input("Your insurer's $17,850 offer is $7,108 under valuation.", at: at(40), offer: "sit_insurer"),
            Self.input("Your insurer's offer is still $7,108 short; a demand letter is ready.", at: at(44), offer: "sit_insurer"),
            Self.input("The founders' event still needs your RSVP.", at: at(12), loops: ["event-rsvp"]),
            Self.input("You've been invited to the founders' event next Tuesday.", at: at(36), loops: ["event-rsvp"]),
            // The same words twice, with no subject: the old fallback.
            Self.input("Your dashboard still needs expense tracking.", at: at(15)),
            Self.input("Your dashboard still needs expense tracking.", at: at(27)),
        ]
        #expect(stream.count == 20)
        var list: [InboxItem] = []
        for i in stream { Self.receive(i, into: &list) }
        // Every repeat folded: one card per subject (and one plain card).
        #expect(list.count == 9)

        let now = at(48)
        let liveOffers: Set<String> = ["sit_scam", "sit_insurer"]
        let sources = InboxLifecycle.Sources(offerLive: { liveOffers.contains($0) },
                                             openLoops: ["hanoi-hotel", "event-rsvp", "family-meet"])
        for (id, outcome) in InboxLifecycle.resolved(list, now: now, sources: sources) {
            if let i = list.firstIndex(where: { $0.id == id }) { InboxLifecycle.archive(&list[i], now: now, outcome: outcome) }
        }
        let open = list.filter { $0.status == .open }
        #expect(Set(open.map(\.subject)) == ["situation:sit_scam", "situation:sit_insurer",
                                             "loop:hanoi-hotel", "loop:event-rsvp", ""])
        #expect(open.count == 5, "one card per live subject")
        #expect(open.first { $0.subject == "situation:sit_scam" }?.body.contains("$4,495") == true, "the newest words")
        let closed = list.filter { $0.status == .done }
        #expect(closed.count == 4)
        #expect(Set(closed.compactMap(\.outcome)) == ["Settled", "No longer current", "Meeting started"])
        #expect(!open.contains { $0.subject == "loop:cash-split" || $0.subject == "situation:sit_precharts" })
        #expect(!open.contains { $0.job == InboxLifecycle.headsUpJob })
    }
}
