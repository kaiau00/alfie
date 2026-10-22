#if DEBUG
import Foundation
import MoeIsland

/// The inbox the snapshots are taken of (`--panel-snapshot`,
/// `--settings-snapshot inbox`): one of each kind, in the words the owner's
/// own Mac produced on 2026-09-29, so the pictures are of real content.
enum InboxSamples {
    static let brief = """
    **Marketing brief, Tue 09-29**

    **Reply draft for you to post (r/mac, "What's one Mac app you installed once and now can't imagine living without?")**
    Only one of today's 9 threads is a real ask that fits. I rewrote the digest's draft to drop the link-style pitch:

    > Not a big-name app, but talking to my mail and calendar from whatever window I'm in, without opening anything first. Saves me a dozen tiny context switches a day. Was skeptical it'd stick and it did.

    Add one concrete example you actually used it for.

    **Overdue: Week 1 ended 09-27 and is still open**
    - 1.1: Record a real 10-second screen clip of "Hey Alfie". The existing one is a mock-up.
    - 1.2: Watch 5 people hit the site cold.
    - 1.5: Email 9to5Mac Indie App Spotlight.

    **Due this week (Week 2, 09-28 to 10-04)**
    - 2.1: Show HN, Tue–Thu, 8–10am ET. Today or tomorrow morning fits.
    - 2.3: Reddit Ads at $25/day for 7 days, once the clip is above the fold.

    **Postiz:** clean. Posts through 09-27 on X, Bluesky, LinkedIn and Dev.to all show published.
    """

    static func items(now: Date = Date()) -> [InboxItem] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

        var rem = NoticeInput(text: "Call the dentist before 5.", at: at(26))
        rem.job = "Dentist"; rem.jobID = "d1"
        var work = NoticeInput(text: "Dana asked for September's invoice. I drafted a reply and attached it.", at: at(166))
        work.offer = "sit_demo"; work.job = "moe-situations"
        var q = NoticeInput(text: "Two of your three replies this week came from r/mac launch threads. How often should I check it?",
                            at: at(316))
        q.options = ["Every day", "Mondays", "Stop"]
        var b = NoticeInput(text: brief, at: at(506))
        b.job = "Alfie marketing standing brief"; b.jobID = "3a26f7d51a3c"
        b.title = "Marketing brief"
        b.summary = "One Reddit reply ready to post, three launch tasks overdue, Show HN due this week."
        var t = NoticeInput(text: "Ticket #12 is fixed: sending from Gmail works again. Nothing for you to do.", at: at(231))
        t.instruction = "ticket"

        var out = [rem, work, q, b, t].enumerated().map { i, input in
            NoticeMaker.make(input, id: "sample-\(i)")
        }
        out[0].seen = false
        var done1 = NoticeMaker.make(NoticeInput(text: "Pick up the dry cleaning.", at: at(300)), id: "sample-done-1")
        done1.kind = .reminder
        done1.status = .done; done1.doneAt = at(260); done1.outcome = "Done"
        var done2 = NoticeMaker.make(NoticeInput(text: "Your cloud computer is set up and running.", at: at(420)), id: "sample-done-2")
        done2.status = .done; done2.doneAt = at(400); done2.outcome = "Got it"
        return out + [done1, done2]
    }

    /// The offer behind the "Ready for you" sample, as the situations
    /// engine writes it, into whatever home the snapshot runs in.
    static func writeOffer(now: Date = Date()) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let sits: [String: Any] = ["sit_demo": [
            "title": "September invoice", "thread_name": "Dana Whitfield", "source": "composio/gmail",
            "offered": ["for": "v1", "at": f.string(from: now.addingTimeInterval(-3600))],
            "prepared": [
                "for": "v1",
                "offer": "Dana asked for September's invoice. It was in Drive under Invoices/2026, so I drafted a reply with it attached.",
                "options": ["Send it as it is", "Ask her which format she needs first"],
                "research": [["point": "Invoice-2026-09.pdf, 84 KB, in Drive › Invoices › 2026"]],
                "draft": "Hi Dana,\n\nHere's the September invoice. Let me know if you need it in another format.\n\nThanks,\nJordan",
            ],
        ]]
        let dir = Paths.home.appendingPathComponent("proactive")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: sits) {
            try? data.write(to: dir.appendingPathComponent("situations.json"))
        }
    }
}
#endif
