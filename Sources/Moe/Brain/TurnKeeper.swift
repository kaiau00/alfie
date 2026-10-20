import Foundation

/// The turn Moe is working on, kept where a sleep or a quit cannot lose it.
///
/// Until 2026-09-18 nothing on the Mac knew a turn was in flight except the
/// URLSession holding its stream. Close the lid on "find me a cheap backpack"
/// and the stream died somewhere in the sleep; on wake the person saw
/// *"Moe is taking too long to answer. Try again."* — no retry, no record
/// that the work had ever started (`docs/AWAY-HANDOFF.md`, slice 1). This is
/// that record and the rule for what to do with it.
///
/// Two things, both small and both testable without a network:
///
/// * **The record.** `~/.moe/turns/inflight.json`: the person's words, when
///   they were sent, the Hermes session, and how many times it has been
///   re-issued. Written at turn start, removed at turn end. A silent turn
///   (a restored transcript, a nudge) is never recorded — nobody is waiting
///   for it.
/// * **The rule.** A turn whose stream broke is re-issued **once**, on the
///   same session, when the break is the kind a sleep causes and the Mac
///   did sleep while it ran. Under a Claude Code brain the child's own
///   transcript holds the partial work, so the re-issue is a resume, not a
///   restart — the text carries a note saying so. Any other failure keeps
///   today's behaviour; a second break gives up and says so, because a
///   retry loop over a broken gateway is worse than one honest error.
///
/// What this does not do: carry the turn to another machine. That is the
/// rest of the handoff plan, and it builds on this record.
enum TurnKeeper {

    struct Record: Codable, Equatable {
        var text: String
        var logAs: String?
        var startedAt: Date
        var sessionID: String
        /// How many times this turn has been re-issued so far. 0 on first send.
        var resumed: Int = 0
        /// The ask's id on the edge (`moe.task_runs`), so a relaunch can ask
        /// who holds it before picking it up. Empty on records from before.
        var task: String = ""
        /// The conversation the turn was on, so a relaunch can open it before
        /// picking the turn up — the session id is derived from it and is
        /// different in every process, so it was never the thing to compare.
        var thread: String = ""
    }

    /// The prefix a re-issued turn carries. The person's own words follow it
    /// unchanged, so the model has both the ask and the reason it is seeing
    /// it again.
    static let resumeNote = """
        (Your Mac went to sleep while you were working on this and the \
        connection dropped. Carry on from wherever you had got to — do not \
        start over, and do not repeat what you already said.)
        """

    /// The same, for a Moe that was quit — or crashed — mid-answer and has
    /// just come back.
    static let relaunchNote = """
        (Moe was closed while working on this and has just started again. \
        Carry on from wherever you had got to — do not start over, and do \
        not repeat what you already said.)
        """

    /// Older than this, a record left by a Moe that quit is history, not a
    /// task: the person has moved on and a reply out of nowhere is noise.
    static let relaunchWindow: TimeInterval = 30 * 60

    static let maxResumes = 1

    // MARK: - The rule

    enum Verdict: Equatable {
        /// Re-issue with `text`, on the same session.
        case resume(text: String)
        /// A sleep broke it, but it had already sent or paid: stop and say so.
        case stop
        /// Fail as today.
        case giveUp
    }

    /// Whether a turn whose stream ended in `error` should be re-issued.
    /// `slept`: the Mac slept at least once while this turn was in flight.
    /// `consequential`: the turn had already reached for a tool that sends,
    /// pays, books or deletes — re-issuing that unasked is how a thing is
    /// done twice, so it stops and says so (`stoppedNote`) instead.
    static func verdict(for record: Record, error: URLError.Code, slept: Bool,
                        consequential: Bool = false) -> Verdict {
        guard slept, record.resumed < maxResumes, isSleepShaped(error) else { return .giveUp }
        if consequential { return .stop }
        return .resume(text: resumeNote + "\n\n" + record.text)
    }

    /// What the person is told when a sleep broke a turn that had already
    /// sent, paid, booked or deleted something.
    static let stoppedNote = "Your Mac went to sleep in the middle of something that sends or pays, "
        + "so Moe stopped rather than risk doing it twice. Say the word and it carries on."

    /// The failures a sleep produces at the socket: the idle timer that ran
    /// out while the process was frozen, the connection the kernel dropped,
    /// the gateway not yet answering as everything comes back. A 4xx/5xx, a
    /// cancel, a bad response are not these.
    static func isSleepShaped(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// The record a relaunched Moe should pick up, or nil: a turn recorded
    /// less than `relaunchWindow` ago that never finished.
    static func leftover(_ record: Record?, now: Date = Date()) -> Record? {
        guard let record, now.timeIntervalSince(record.startedAt) < relaunchWindow,
              record.resumed < maxResumes else { return nil }
        return record
    }

    // MARK: - The record

    static func write(_ record: Record, to url: URL = Paths.inflightTurn) {
        do {
            // The person's words, and the brief around them: the conversation
            // store's own permissions (0700 / 0600), not the defaults.
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(record).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.write("turn keeper: could not write \(url.lastPathComponent): \(error)")
        }
    }

    static func read(from url: URL = Paths.inflightTurn) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Record.self, from: data)
    }

    static func clear(_ url: URL = Paths.inflightTurn) {
        try? FileManager.default.removeItem(at: url)
    }
}
