import Foundation
import Testing
@testable import MoeIsland

/// `ReplySignal` is only as good as where it is called from, and where it is
/// called from lives in `Sources/Moe/Conductor.swift` — an executable target,
/// which Swift cannot import into a test. So this reads the source.
///
/// That is an unusual thing for a test to do and it is deliberate. The whole
/// value of the signal is a claim about *call sites*: armed in exactly one
/// place, fired at every way a turn can end and nowhere else. A change that
/// arms it a second time — a background turn setting `awaitingReply`, say —
/// would not fail any behavioural test; it would just quietly start opening a
/// panel over somebody's video call for turns nobody asked for. These checks
/// fail loudly instead.
///
/// If one of these fails after a legitimate refactor, the fix is to re-read
/// docs/PANEL-FINDINGS.md §5 and update the count here on purpose.
struct ConductorWiringTests {

    private static let source: String? = {
        let root = URL(fileURLWithPath: #filePath)   // Tests/MoeIslandTests/…
            .deletingLastPathComponent()             // Tests/MoeIslandTests
            .deletingLastPathComponent()             // Tests
            .deletingLastPathComponent()             // repo root
        return try? String(contentsOf: root.appendingPathComponent("Sources/Moe/Conductor.swift"),
                           encoding: .utf8)
    }()

    /// The block of the brain's event handler for one case: from its label to
    /// the next case at the same indent, or to the close of the switch — the
    /// last case has no next case, and running to the end of the file would
    /// sweep in half the Conductor.
    private func block(_ label: String, in source: String) -> String? {
        guard let start = source.range(of: "case .\(label)(") else { return nil }
        let rest = source[start.upperBound...]
        let ends = ["\n            case .", "\n            }"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        guard let end = ends.min() else { return String(rest) }
        return String(rest[..<end])
    }

    private func count(_ needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    @Test func theConductorSourceIsWhereThisExpectsItToBe() {
        #expect(Self.source != nil,
                "Sources/Moe/Conductor.swift moved; these wiring checks need its new path.")
    }

    // MARK: - One door onto the island

    /// The amber pulse is `pendingNudge`, and the machinery filter sits in
    /// the one function that sets it. A second setter is a second way onto
    /// the island with no filter in it — which is what `watchForNudges` was:
    /// it assigned `pendingNudge` straight from nudge.json.
    ///
    /// If this fails because you added a route, the fix is to call
    /// `queueReminder`, not to raise the count.
    @Test func exactlyOneFunctionPutsSomethingOnTheIsland() throws {
        let source = try #require(Self.source)
        // `text`, and nothing built from it: the timestamp is no longer
        // glued onto the words at all — it is `pendingNudgeWhen`, its own
        // line on the card, put back in front only for the speaking. So
        // what reaches the island is exactly what the filter saw.
        // Since the inbox (docs/INBOX.md) the one place is `activate`, which
        // loads an item that came through `receiveNotice` — past the filter.
        #expect(count("pendingNudge = n.body", in: source) == 1,
                "Something other than activate puts an item's words on the island.")
        #expect(count("self.pendingNudge = ", in: source) == 0,
                "Something sets pendingNudge from outside queueReminder. Call queueReminder instead: the machinery filter lives in it.")
        #expect(count("queueReminder(", in: source) >= 3,
                "The inbox and nudge.json both reach the island through queueReminder.")
    }

    /// "Earlier, at 9:30 AM: ⚠️ Cron 'moe-drain-intents' failed: …" was on
    /// the island seven times: a prefix glued on in front of a
    /// start-anchored filter walked the text past it. The inbox shows the
    /// time on its own line and glues nothing on at all; what is checked is
    /// that both doors into it run the filter before anything is kept, and
    /// that nothing builds the shown text from parts.
    @Test func theFilterRunsBeforeAnythingReachesTheInbox() throws {
        let source = try #require(Self.source)
        #expect(count(#""Earlier, at \("#, in: source) == 0,
                "A caller builds an 'Earlier, at' prefix again; the inbox shows the time on its own.")
        for door in ["func queueReminder(", "func receive(_ m: ReminderChannels.Message)"] {
            let start = try #require(source.range(of: door), "\(door) is gone")
            let rest = String(source[start.upperBound...])
            let gate = try #require(rest.range(of: "MachineryNotice.isJobFailure("), "\(door) lost the filter")
            let kept = try #require(rest.range(of: "receiveNotice("), "\(door) no longer reaches the inbox")
            #expect(gate.lowerBound < kept.lowerBound, "\(door) keeps the message before filtering it.")
        }
        #expect(count(##"pendingNudge = \("##, in: source) == 0,
                "Something builds the shown text from parts again; the filter only ever saw one of them.")
    }

    // MARK: - Armed by the question, once

    /// docs/PANEL-FINDINGS.md §5: "`awaitingReply` is set in `submit` and
    /// nowhere else, which makes it exactly *the user asked*." That single
    /// arming point is the whole reason the silent background turns — the
    /// ones that keep the session warm or file a meeting — cannot fire this.
    @Test func armedInExactlyOnePlace() throws {
        let source = try #require(Self.source)
        #expect(count("awaitingReply = true", in: source) == 1,
                "A second place sets awaitingReply. If it is a real question, arm the signal there too; if it is a background turn, it must not be set at all.")
        #expect(count("replySignal.asked()", in: source) == 1)
    }

    /// And armed *there*, not somewhere that merely looks like a question.
    @Test func armedBesideTheFlagItMirrors() throws {
        let source = try #require(Self.source)
        let flag = try #require(source.range(of: "awaitingReply = true"))
        let asked = try #require(source.range(of: "replySignal.asked()"))
        let between = source[flag.upperBound..<asked.lowerBound]
        #expect(asked.lowerBound > flag.lowerBound)
        #expect(between.components(separatedBy: "\n").count <= 5,
                "replySignal.asked() has drifted away from awaitingReply = true; they are the same fact and must stay together.")
    }

    // MARK: - Fired by every way a turn can end

    /// A turn ends four ways. Three of them are failures, and §5 is explicit
    /// that failure fires: a question that got an error is still answered,
    /// and silence is the one outcome that reads as being ignored.
    @Test func firedFromEveryTerminalEvent() throws {
        let source = try #require(Self.source)
        for label in ["turnFinished", "error", "failedToLaunch", "exited"] {
            let body = try #require(block(label, in: source), "no `case .\(label)` in the handler")
            #expect(body.contains("replySignal.ended("),
                    "`case .\(label)` ends a turn without announcing a reply. A question that ends there gets silence.")
        }
    }

    /// Three of those four carry `failed: true`. Only `turnFinished` is an
    /// answer in the ordinary sense.
    @Test func failuresAreMarkedAsFailures() throws {
        let source = try #require(Self.source)
        for label in ["error", "failedToLaunch", "exited"] {
            let body = try #require(block(label, in: source))
            #expect(body.contains("failed: true"))
        }
        let finished = try #require(block("turnFinished", in: source))
        #expect(!finished.contains("failed: true"))
    }

    // MARK: - And by nothing else

    /// Not on a streaming delta, so nothing built on this flaps while words
    /// arrive; not on a status change, which is a clock tick with words on it.
    @Test func neverFiredFromADeltaOrAStatus() throws {
        let source = try #require(Self.source)
        for label in ["textDelta", "status", "toolStarted", "toolFinished", "ready"] {
            let body = try #require(block(label, in: source), "no `case .\(label)` in the handler")
            #expect(!body.contains("replySignal"),
                    "`case .\(label)` touches the reply signal. It is not the end of a turn.")
        }
    }

    /// One announcement path, so "fires once" is a property of the type
    /// rather than of four call sites agreeing with each other.
    @Test func thereIsExactlyOnePlaceTheCallbackIsCalled() throws {
        let source = try #require(Self.source)
        #expect(count("onReply?(", in: source) == 1)
    }

    /// A question that was withdrawn is not a question that got an answer:
    /// ⌘N, opening another thread, stopping everything, and rebuilding the
    /// brain all throw the turn away, and none of them should open a panel.
    @Test func everyAbandonedTurnDisarms() throws {
        let source = try #require(Self.source)
        // One per place that clears `awaitingReply` outside the event handler.
        // Its own declaration is not a clearing.
        let cleared = count("awaitingReply = false", in: source)
                    - count("var awaitingReply = false", in: source)
        let inHandler = ["turnFinished", "error", "failedToLaunch", "exited"]
            .compactMap { block($0, in: source) }
            .reduce(0) { $0 + count("awaitingReply = false", in: $1) }
        #expect(count("replySignal.abandoned()", in: source) == cleared - inHandler,
                "A turn is being thrown away without disarming the signal — the next thing to end will be announced as the answer to a question that is gone.")
    }
}
