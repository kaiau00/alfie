import Foundation
import Testing
@testable import MoeIsland

/// The inbox's model (docs/INBOX.md). The brief below is the one that reached
/// the island on 2026-09-29 as three cut-off lines: its shape, abridged.
struct InboxItemTests {

    static let brief = """
    **Marketing brief, Tue 09-29**

    **Reply draft for you to post (r/mac, "What's one Mac app you installed once and now can't imagine living without?")**
    Only one of today's 9 threads is a real ask that fits.

    > Not a big-name app, but talking to my mail and calendar from whatever window I'm in, without opening anything first.
    > Was skeptical it'd stick and it did.

    Add one concrete example you actually used it for.

    **Overdue: Week 1 ended 09-27 and is still open**
    - 1.1: Record a real 10-second screen clip of "Hey Alfie".
    - 1.2: Watch 5 people hit the site cold.

    **Due this week (Week 2, 09-28 to 10-04)**
    - 2.1: Show HN, Tue–Thu, 8–10am ET.

    **Postiz:** clean. Posts through 09-27 all show published.
    """

    static func input(_ text: String, job: String = "Alfie marketing standing brief",
                      jobID: String = "3a26f7d51a3c") -> NoticeInput {
        var m = NoticeInput(text: text, at: Date(timeIntervalSince1970: 1_790_000_000))
        m.job = job
        m.jobID = jobID
        return m
    }

    @Test func aLongReportIsABriefWithATitleAndASummaryOfItsSections() {
        let n = NoticeMaker.make(Self.input(Self.brief))
        #expect(n.kind == .brief)
        #expect(n.title == "Marketing brief, Tue 09-29")
        // Its sections, not its first sentence cut short.
        #expect(n.summary == "Reply draft for you to post · Overdue · Due this week · Postiz")
        #expect(n.body == Self.brief)
        #expect(n.source == "Alfie marketing standing brief")
    }

    @Test func aShortReminderTheyScheduledIsAReminder() {
        let n = NoticeMaker.make(Self.input("Call the dentist before 5.", job: "Dentist", jobID: "abc"))
        #expect(n.kind == .reminder)
        #expect(n.title == "Call the dentist before 5.")
        #expect(n.summary.isEmpty)
    }

    @Test func aFollowUpIsAReminderSoDoneCanCloseIt() {
        var m = Self.input("The deck you promised Sam was due today. Did it go out?", job: "moe-proactive", jobID: "x")
        m.loops = ["deck-for-sam"]
        #expect(NoticeMaker.make(m).kind == .reminder)
    }

    @Test func anOfferIsReadyWork() {
        var m = Self.input("Dana asked for the September invoice. I drafted a reply.", job: "moe-situations", jobID: "")
        m.offer = "sit-1"
        let n = NoticeMaker.make(m)
        #expect(n.kind == .work)
        // Short enough to be its own title: no summary repeating it.
        #expect(n.title == "Dana asked for the September invoice. I drafted a reply.")
        #expect(n.summary.isEmpty)
    }

    /// Measured 2026-09-29: the row read "Andrew Wilson Follow Up Discussion
    /// is tomorrow at 3 PM… · Andrew Wilson Follow Up Discussion is tomorrow
    /// at 3 PM (Teams meeting). Want me to…" — the title, then itself again.
    @Test func theSummaryNeverRepeatsTheTitle() {
        let text = "Andrew Wilson Follow Up Discussion is tomorrow at 3 PM (Teams meeting). Want me to pull your recent work on the Andrew agent?"
        let n = NoticeMaker.make(Self.input(text, job: "moe-calendar-heads-up", jobID: ""))
        #expect(n.title == "Andrew Wilson Follow Up Discussion is tomorrow at 3 PM (Teams meeting).")
        #expect(n.summary == "Want me to pull your recent work on the Andrew agent?")
    }

    @Test func optionsMakeAQuestion() {
        var m = Self.input("Two of your three replies came from r/mac. How often should I check it?", job: "", jobID: "")
        m.options = ["Every day", "Mondays", "Stop"]
        let n = NoticeMaker.make(m)
        #expect(n.kind == .question)
        #expect(n.options == ["Every day", "Mondays", "Stop"])
    }

    @Test func aWriterSaysWhatItIsAndTheirWordsWin() {
        var m = Self.input(Self.brief)
        m.kind = "headsUp"
        m.title = "Morning marketing"
        m.summary = "One reply to post; three things overdue."
        let n = NoticeMaker.make(m)
        #expect(n.kind == .headsUp)
        #expect(n.title == "Morning marketing")
        #expect(n.summary == "One reply to post; three things overdue.")
    }

    @Test func somethingWithNoJobAndNothingToDoIsAHeadsUp() {
        var m = Self.input("Ticket #12 is fixed: sending from Gmail works again.", job: "", jobID: "")
        m.instruction = "tickets.sh"
        #expect(NoticeMaker.make(m).kind == .headsUp)
    }

    @Test func theCardLaysTheBriefOutAsHeadingsDraftsAndLists() {
        let blocks = NoticeBody.blocks(Self.brief)
        #expect(blocks.first == .heading("Marketing brief, Tue 09-29"))
        #expect(blocks.contains(.draft("Not a big-name app, but talking to my mail and calendar from whatever window I'm in, without opening anything first.\nWas skeptical it'd stick and it did.")))
        #expect(blocks.contains(.bullets(["1.1: Record a real 10-second screen clip of \"Hey Alfie\".",
                                         "1.2: Watch 5 people hit the site cold."])))
        #expect(blocks.contains(.heading("Overdue: Week 1 ended 09-27 and is still open")))
        // "**Postiz:** clean." is a sentence that starts bold, not a heading.
        #expect(blocks.contains(.prose("**Postiz:** clean. Posts through 09-27 all show published.")))
    }

    @Test func toDosAreTheirOwnList() {
        #expect(NoticeBody.blocks("- [ ] send the note\n- [ ] record the clip")
                == [.todo(["send the note", "record the clip"])])
    }

    @Test func snoozedAndHiddenAreStillWaitingButNotOnTheIsland() {
        var n = NoticeMaker.make(Self.input("Call the dentist.", job: "Dentist", jobID: "a"))
        let now = Date()
        #expect(n.onIsland(now: now))
        n.snoozedUntil = now.addingTimeInterval(600)
        #expect(!n.isWaiting(now: now))
        #expect(n.isWaiting(now: now.addingTimeInterval(601)))
        n.snoozedUntil = nil
        n.hidden = true
        #expect(n.isWaiting(now: now))
        #expect(!n.onIsland(now: now))
        n.status = .done
        #expect(!n.isWaiting(now: now))
    }

    @Test func aReplyGoesToANewConversationUnlessItIsAboutThisOne() {
        let n = NoticeMaker.make(Self.input(Self.brief))
        let now = Date()
        // Talking about the launch film: a new conversation.
        #expect(!NoticeThread.continuesHere(notice: n, recent: ["the launch film looks like a slideshow"],
                                            lastActivity: now, now: now))
        // Talking about the Postiz queue and what is overdue, a minute ago: here.
        #expect(NoticeThread.continuesHere(notice: n, recent: ["is anything overdue on postiz this week?"],
                                           lastActivity: now.addingTimeInterval(-60), now: now))
        // The same words an hour ago: that conversation is over.
        #expect(!NoticeThread.continuesHere(notice: n, recent: ["is anything overdue on postiz this week?"],
                                            lastActivity: now.addingTimeInterval(-3600), now: now))
        // Nothing said yet: never "this one".
        #expect(!NoticeThread.continuesHere(notice: n, recent: [], lastActivity: now, now: now))
    }

    @Test func theIslandGrowsWithItsRowsAndStopsAtItsCap() {
        let one = InboxLayout.height(rows: [("Call the dentist", "", true)])
        let two = InboxLayout.height(rows: [("Call the dentist", "", true), ("Ticket fixed", "Nothing to do.", false)])
        #expect(two > one)
        let many = InboxLayout.height(rows: Array(repeating: ("A", String(repeating: "word ", count: 60), true), count: 20))
        #expect(many == InboxLayout.maxHeight)
        #expect(InboxLayout.height(rows: []) == InboxLayout.header + InboxLayout.empty)
    }

    @Test func itSurvivesARoundTripThroughJSON() throws {
        var n = NoticeMaker.make(Self.input(Self.brief))
        n.snoozedUntil = Date(timeIntervalSince1970: 1_790_000_600)
        let back = try JSONDecoder().decode(InboxItem.self, from: JSONEncoder().encode(n))
        #expect(back == n)
    }
}
