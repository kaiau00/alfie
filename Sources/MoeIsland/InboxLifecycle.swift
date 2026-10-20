import Foundation

/// How a card lives and ends (docs/INBOX-QUIET.md, slice 1): one card per
/// real-world thing, updated in place; closed by its source when the thing
/// it was about is over; and the one-time archive of the backlog. The pure
/// half, so it can be tested without a Mac — `Conductor` holds the list and
/// reads the files.
///
/// The week this answers (2026-09-29 → 10-06): the scam targeting Israel was
/// seven cards, the Andrew meeting six, Hanoi six, Kaporos seven — each a
/// reworded repeat of one thing — and nothing ever closed a card from its
/// source: a meeting that had passed, a follow-up that was closed and an
/// offer that was no longer current all stayed in the count for good.
public enum InboxLifecycle {

    // MARK: One card per subject

    /// The open card (snoozed or hidden included) about the same thing, if
    /// there is one. A finished card is never reopened: Done or ✕ is silence
    /// until a new card arrives.
    public static func openCard(about subject: String, in notices: [InboxItem]) -> Int? {
        guard !subject.isEmpty else { return nil }
        return notices.firstIndex { $0.status == .open && $0.subject == subject }
    }

    /// A newer notice about the same thing, folded into the card already
    /// there: its words and its handles are the newer ones, it keeps its id
    /// (so an open reading card stays on it), and it is raised back up —
    /// unread, back on the island, out of any snooze.
    public static func absorb(_ new: InboxItem, into old: inout InboxItem) {
        old.kind = new.kind
        old.title = new.title
        old.summary = new.summary
        old.body = new.body
        old.at = max(old.at, new.at)
        old.options = new.options
        if !new.source.isEmpty { old.source = new.source }
        old.job = new.job
        old.jobID = new.jobID
        if !new.loops.isEmpty { old.loops = new.loops }
        old.said = new.said
        old.instruction = new.instruction
        if !new.offer.isEmpty { old.offer = new.offer }
        old.awayCarry = new.awayCarry
        old.expiredText = new.expiredText
        old.openThread = new.openThread
        old.seen = false
        old.hidden = false
        old.snoozedUntil = nil
    }

    // MARK: Closed by their source

    /// What the sweep can know about the world, each part nil when it could
    /// not be read: an unreadable file closes nothing.
    public struct Sources {
        /// Whether a situation's offer is still current (`SituationOffer.load`),
        /// nil when the situations file could not be read.
        public var offerLive: (String) -> Bool?
        /// The follow-ups open in the ledger (`proactive/open.json`), nil
        /// when it could not be read.
        public var openLoops: Set<String>?

        public init(offerLive: @escaping (String) -> Bool?, openLoops: Set<String>?) {
            self.offerLive = offerLive
            self.openLoops = openLoops
        }
    }

    /// A card's source gets this long before the sweep believes it is over.
    /// The situations engine marks an offer offered only after its delivery
    /// returns, and a follow-up closed on the away machine reaches this
    /// Mac's ledger on the next merge: a card younger than this is left be.
    public static let grace: TimeInterval = 10 * 60

    /// The calendar heads-up job (moe-calendar-heads-up.py).
    public static let headsUpJob = "moe-calendar-heads-up"
    /// A heads-up whose meeting time cannot be read closes this long after
    /// it arrived — the job says it about ten minutes before.
    public static let headsUpLife: TimeInterval = 30 * 60

    /// The open cards whose source has resolved, each with the word the Done
    /// list shows for it.
    public static func resolved(_ notices: [InboxItem], now: Date, sources: Sources) -> [(id: String, outcome: String)] {
        var out: [(String, String)] = []
        for n in notices where n.status == .open {
            if n.job == headsUpJob {
                let start = meetingStart(n) ?? n.at.addingTimeInterval(headsUpLife)
                if now >= start { out.append((n.id, "Meeting started")) }
                continue
            }
            guard now.timeIntervalSince(n.at) >= grace else { continue }
            if !n.offer.isEmpty {
                if sources.offerLive(n.offer) == false { out.append((n.id, "No longer current")) }
                continue
            }
            if !n.loops.isEmpty, let open = sources.openLoops, n.loops.allSatisfy({ !open.contains($0) }) {
                out.append((n.id, "Settled"))
            }
        }
        return out
    }

    /// When a heads-up's meeting starts, from its own sentence ("… starts
    /// in 9 minutes", "… starts in a minute", "… is starting now", one per
    /// line when several were due), counted from when the card arrived. The
    /// latest, so a card naming two meetings stays until both have started.
    /// Nil when no line says.
    public static func meetingStart(_ n: InboxItem) -> Date? {
        var latest: TimeInterval?
        for line in n.body.split(separator: "\n") {
            let l = line.lowercased()
            var minutes: Double?
            if l.contains("is starting now") {
                minutes = 0
            } else if l.contains("starts in a minute") {
                minutes = 1
            } else if let r = l.range(of: #"starts in (\d{1,4}) minutes"#, options: .regularExpression) {
                let digits = l[r].filter(\.isNumber)
                minutes = Double(digits)
            }
            if let m = minutes { latest = max(latest ?? 0, m * 60) }
        }
        return latest.map { n.at.addingTimeInterval($0) }
    }

    // MARK: The backlog, once

    /// How recent a prepared-work card must be to survive the archive: it is
    /// still live signal.
    public static let keepRecentWork: TimeInterval = 48 * 3600

    /// The cards the one-time archive finishes (decision 10): every open card
    /// except ready work — an offer, or a card that is work — from the last
    /// two days.
    public static func backlog(_ notices: [InboxItem], now: Date) -> [String] {
        notices.filter { n in
            guard n.status == .open else { return false }
            let work = n.kind == .work || !n.offer.isEmpty
            return !(work && now.timeIntervalSince(n.at) < keepRecentWork)
        }.map(\.id)
    }

    /// Finished as archived: kept under Done for the normal week, like any
    /// finished card.
    public static func archive(_ n: inout InboxItem, now: Date, outcome: String = "Archived") {
        guard n.status == .open else { return }
        n.status = .done
        n.doneAt = now
        n.outcome = outcome
        n.seen = true
    }
}
