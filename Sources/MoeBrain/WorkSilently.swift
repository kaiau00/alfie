import Foundation

/// "Work silently": the person asked Moe to stop talking them through a long
/// job, for this turn only, and to just tell them the answer at the end.
///
/// A long turn — a `browser_exec` run, computer use, a chain of tool calls —
/// is narrated three ways: the step table (`SpokenStep`, "Working through the
/// page"), the twelve-second backstop ("Still on it."), and the model's own
/// interim sentences, which stream into the same reply as the answer and are
/// spoken as they arrive. The owner's report was that on long work this is
/// repetitive. This is the switch, and the rules for what it silences.
///
/// It silences narration, not the job's account of itself:
///
/// - the confirmation sheet's announcement and its one reminder are still
///   said, because the job cannot go on until the person acts;
/// - errors never pass through here at all;
/// - the island keeps the step as text — silent, not invisible;
/// - and the answer is still spoken when the turn ends.
///
/// **Final versus interim.** The reply is one stream of text, so "the answer"
/// has to be found in it. Hermes reports every tool step as it starts, and a
/// step can only start after whatever the model wrote before it — so the
/// streamed length at each step is an exact boundary, not a guess about
/// wording. The answer is the text after the last step. When a turn ends with
/// nothing after its last step (the model wrote "Done — it's booked." and then
/// ran one more bookkeeping call), the last segment that has any words in it
/// is spoken instead: a person who asked for quiet must still hear an answer,
/// and one interim line too many is a far smaller failure than none at all.
public struct WorkSilently: Equatable, Sendable {

    /// Whether progress speech is off for the turn in flight.
    public private(set) var isOn = false

    /// Where each tool step began, as a character count into the streamed
    /// reply. Recorded for every step whether or not the switch is on, so a
    /// press halfway through a turn still knows where the answer starts.
    public private(set) var stepOffsets: [Int] = []

    public init() {}

    /// The kinds of thing Moe says during a turn.
    public enum Line: Sendable, CaseIterable {
        /// A step from the table: "Working through the page".
        case step
        /// The backstop into a long silence: "Still on it."
        case stillWorking
        /// The model's own words, spoken while the turn is still working.
        case interim
        /// "It's on your screen — press Send." The person has to act.
        case confirmSheet
        /// The one reminder while a sheet waits. The person still has to act.
        case confirmReminder
        /// The reply, once the turn has finished.
        case finalReply
    }

    /// Whether this line is said aloud with the switch as it is.
    public func speaks(_ line: Line) -> Bool {
        switch line {
        case .confirmSheet, .confirmReminder, .finalReply: return true
        case .step, .stillWorking, .interim: return !isOn
        }
    }

    /// Whether the island offers the button at all: only while a spoken turn
    /// is working. A typed turn is already silent, and a turn that has ended
    /// or been abandoned has nothing left to narrate.
    public static func offered(awaitingReply: Bool, replySpeaks: Bool, abandoned: Bool) -> Bool {
        awaitingReply && replySpeaks && !abandoned
    }

    /// The button's words for the switch as it is.
    public var buttonLabel: String { isOn ? Self.talkLabel : Self.silentLabel }
    public static let silentLabel = "Work silently"
    public static let talkLabel = "Talk me through it"

    /// Flip the switch. Returns the new state.
    @discardableResult
    public mutating func toggle() -> Bool {
        isOn.toggle()
        return isOn
    }

    /// A new turn: talk it through again, and forget the old boundaries.
    public mutating func reset() {
        isOn = false
        stepOffsets.removeAll()
    }

    /// A tool step started with `offset` characters of reply streamed.
    public mutating func stepStarted(at offset: Int) {
        guard offset >= 0 else { return }
        if let last = stepOffsets.last, offset <= last { return }
        stepOffsets.append(offset)
    }

    /// Whether switching on should cut what is already queued to be said.
    ///
    /// Mid-turn, everything queued is narration — the answer has not been
    /// written yet, and if its first sentences were already playing they are
    /// said again from the start at the end of the turn. The exception is a
    /// confirmation sheet that is up: its announcement may be the thing
    /// playing, and that line is the person's cue to act.
    public static func cutsQueuedSpeech(confirmWaiting: Bool) -> Bool {
        !confirmWaiting
    }

    /// Where the spoken answer starts in the finished reply, as a character
    /// offset: the text after the last step that has words in it, or the
    /// whole reply when no step ran. `text.count` when there is nothing to say.
    public func finalReplyStart(in text: String) -> Int {
        let count = text.count
        let bounds = [0] + stepOffsets.map { min($0, count) }
        var end = count
        for start in bounds.reversed() where start <= end {
            let segment = Self.slice(text, from: start, to: end)
            if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return start
            }
            end = start
        }
        return count
    }

    private static func slice(_ text: String, from: Int, to: Int) -> Substring {
        let lower = text.index(text.startIndex, offsetBy: from)
        let upper = text.index(text.startIndex, offsetBy: to)
        return text[lower..<upper]
    }
}
