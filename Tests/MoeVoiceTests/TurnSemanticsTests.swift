import Foundation
import Testing
@testable import MoeVoice

/// The words' vote at a pause (`TurnSemantics`) and how `EndpointPolicy`
/// fuses it with the score, the pause so far and the turn's length.
struct TurnSemanticsTests {

    typealias E = EndpointPolicy.Evidence
    typealias R = TurnSemantics.Reading

    // MARK: The rules

    /// A clause cannot end on a preposition, a determiner, an auxiliary, a
    /// question word or a subject with no verb — as the recogniser writes
    /// it, lowercase and unpunctuated.
    @Test func wordsThatNeedMoreAreUnfinished() {
        for text in ["send the file to", "put it on my", "remind me where", "can you tell me what",
                     "the meeting should", "and then i", "it's kind of", "look up the one in",
                     "book it for tuesday or", "i need to email the landlord because"] {
            #expect(TurnSemantics.read(text) == .unfinished, "\(text)")
        }
    }

    /// An utterance that is only a way in: nothing to act on yet.
    @Test func anOpenerAloneIsUnfinished() {
        for text in ["so", "okay so", "can you", "i was thinking", "hey alfie", "what about"] {
            #expect(TurnSemantics.read(text) == .unfinished, "\(text)")
        }
    }

    /// The closed set of whole answers — matched on the whole utterance only.
    @Test func aWholeAnswerIsFinishedButOnlyWhole() {
        for text in ["yes", "Not yet.", "yeah go ahead", "okay do it", "that's right", "no thanks"] {
            #expect(TurnSemantics.read(text) == .finished, "\(text)")
        }
        #expect(TurnSemantics.read("tell her yes") == .unknown)
        #expect(TurnSemantics.read("and no") != .finished)
    }

    /// Most requests are a clause that could end or go on: the rules have no
    /// opinion, and a recogniser's full stop does not give them one — it puts
    /// one on every clause it closes, which is the very pause at issue.
    @Test func aPlainClauseIsUnknownFullStopOrNot() {
        for text in ["what time does the pharmacy close today", "Move my three o'clock to Friday.",
                     "turn the volume down a little", "text dan that i'm on my way", "what should i do",
                     "i'll call you", "me too please"] {
            #expect(TurnSemantics.read(text) == .unknown, "\(text)")
        }
    }

    /// A punctuating recogniser's comma or ellipsis says more is coming.
    @Test func aTrailingCommaOrEllipsisIsUnfinished() {
        #expect(TurnSemantics.read("Book the table for seven,") == .unfinished)
        #expect(TurnSemantics.read("Book the table for seven…") == .unfinished)
    }

    @Test func theModelIsReadOnlyForItsTwoWordsAndOnlyWhereTheRulesAreSilent() {
        #expect(TurnSemantics.parseModelAnswer(" DONE.") == .finished)
        #expect(TurnSemantics.parseModelAnswer("more") == .unfinished)
        #expect(TurnSemantics.parseModelAnswer("It depends") == nil)
        #expect(TurnSemantics.combine(rules: .unfinished, model: .finished) == (.unfinished, .rules))
        #expect(TurnSemantics.combine(rules: .unknown, model: .finished) == (.finished, .model))
        #expect(TurnSemantics.combine(rules: .unknown, model: nil) == (.unknown, .rules))
    }

    // MARK: Fusion in the policy

    /// `fitted` (what shipped before) never reads meaning: every semantic
    /// weight is zero, so its plans are the same whatever the model says.
    @Test func theOldFitIgnoresMeaning() {
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            for text in ["yes", "remind me where", "book a table for two"] {
                let a = EndpointPolicy.fitted.plan(E(p: p, text: text, pauseSoFar: 0.35), onStall: false)
                let b = EndpointPolicy.fitted.plan(E(p: p, text: text, pauseSoFar: 0.35, model: .finished), onStall: false)
                #expect(a == b, "p=\(p) \(text)")
            }
        }
    }

    /// A confident "finished" on words that cannot end there ("…remind me
    /// where") was decided at once; read for meaning, it waits the dangler
    /// hold first — and a weak one waits for the mid-clause ceiling.
    @Test func finishedAudioOnUnfinishedWordsWaits() {
        var policy = EndpointPolicy.fitted
        let e = E(p: 0.95, text: "remind me where", pauseSoFar: 0.35)
        #expect(policy.plan(e, onStall: false).reason == .turnModel)   // "where" is not an old dangler
        policy.semanticDangles = true
        policy.danglerWait = 1.2
        let plan = policy.plan(e, onStall: false)
        #expect(plan.reason == .verdictHold)
        #expect(abs(plan.decideIn - 0.85) < 1e-9)                       // 1.2 of quiet, 0.35 heard
        let weak = policy.plan(E(p: 0.6, text: "remind me where", pauseSoFar: 0.35), onStall: false)
        #expect(weak.reason == .ceiling)
        #expect(abs(weak.decideIn - policy.midClauseWait) < 1e-9)       // from the verdict
    }

    /// Clearly finished words go sooner; a clause that could go on waits
    /// longer. The reply's hold is the lever, the decision still starts the
    /// brain at most `maxHold` ahead of it.
    @Test func finishedGoesSoonerAndAnOpenClauseWaitsLonger() {
        var policy = EndpointPolicy.fitted
        policy.finishedLess = 0.6
        policy.unknownMore = 0.8
        func quiet(_ text: String, model: R? = nil) -> Double {
            let plan = policy.plan(E(p: 0.95, text: text, pauseSoFar: 0.35, model: model), onStall: false)
            return 0.35 + plan.decideIn + plan.hold                    // quiet when the reply is let out
        }
        #expect(abs(quiet("not yet") - (1.4 + 0.05 - 0.6)) < 1e-9)
        #expect(abs(quiet("book a table for two") - (1.4 + 0.05 + 0.8)) < 1e-9)
        // The model's "finished" has its own weight — zero here.
        #expect(abs(quiet("book a table for two", model: .finished) - (1.4 + 0.05)) < 1e-9)
        policy.modelFinishedLess = 0.3
        #expect(abs(quiet("book a table for two", model: .finished) - (1.4 + 0.05 - 0.3)) < 1e-9)
        // …and the brain never runs more than maxHold ahead of the reply.
        let long = policy.plan(E(p: 0.95, text: "book a table for two", pauseSoFar: 0.35), onStall: false)
        #expect(long.hold <= 0.8 + 1e-9)
        #expect(long.decideIn > 0)
    }

    /// The model's "more" makes words dangle only with `modelDangles`.
    @Test func theModelsMoreIsItsOwnSwitch() {
        var policy = EndpointPolicy.fitted
        policy.semanticDangles = true
        let e = E(p: 0.95, text: "look up a good italian place near the office", pauseSoFar: 0.35, model: .unfinished)
        #expect(policy.plan(e, onStall: false).reason == .turnModel)
        policy.modelDangles = true
        #expect(policy.plan(e, onStall: false).reason == .verdictHold)
    }

    /// The owner's pause habit is a floor under the release, never a ceiling.
    @Test func theOwnersFloorOnlyEverWaitsLonger() {
        var policy = EndpointPolicy.fitted
        let e = E(p: 0.95, text: "book a table for two", pauseSoFar: 0.35)
        let before = policy.plan(e, onStall: false)
        policy.ownerQuietFloor = 2.2
        let after = policy.plan(e, onStall: false)
        #expect(abs(0.35 + after.decideIn + after.hold - 2.2) < 1e-9)
        policy.ownerQuietFloor = 0.5
        #expect(policy.plan(e, onStall: false) == before)
    }

    // MARK: The mid-clause ceiling and the continuation window stay

    /// Whatever the meaning weights, weak "finished" on dangling words still
    /// waits the 6 s mid-clause ceiling from the verdict (review H5).
    @Test func theShippedPolicyKeepsTheSixSecondCeiling() {
        let plan = EndpointPolicy.shipped.plan(E(p: 0.1, text: "and then um", pauseSoFar: 0.4), onStall: false)
        #expect(plan.reason == .ceiling)
        #expect(abs(plan.decideIn - 6.0) < 1e-9)
    }

    // MARK: A turn-bench tape the old policy cut off

    /// `dev-Amina-pause-03@clean` from the turn bench's dev voices, as
    /// recorded (Silero, Parakeet, Smart Turn v3.2): "Add milk and eggs to the
    /// shopping list, [1.37 s] and bread if we're out." Smart Turn says 0.96–0.98
    /// through the breath. `fitted` lets the reply out at ~1.43 s of quiet — the
    /// person is heard again at 1.52 s — a cut-off; the shipped policy holds an
    /// open clause 0.3 s longer, and the second half joins the first.
    @Test func aBreathTheOldPolicyAnsweredIntoIsWaitedOut() throws {
        let tape = try JSONDecoder().decode(TurnTape.self, from: Data(Self.aminaPause03.utf8))
        func score(_ policy: EndpointPolicy) -> EotScore.Turn {
            var tuning = VoiceMachine.Tuning()
            tuning.conversation = true
            tuning.endpoint = policy
            return EotScore.score(tape, PolicyReplay.run(tape, PolicyReplay.Config(tuning: tuning, inferenceSeconds: 0.06)))
        }
        let old = score(.fitted), new = score(.shipped)
        #expect(old.commitCuts == 1)
        #expect(new.commitCuts == 0)
        #expect(new.continuations >= 1)
        // …and the whole turn is answered no later than before (Smart Turn
        // says 0.10 at the real end, so both wait the mid-clause ceiling there).
        let o = try #require(old.commitLatency), n = try #require(new.commitLatency)
        #expect(n <= o + 1e-9)
    }

    static let aminaPause03 = #"{"truth":{"holds":[{"end":4.6972,"start":3.33}],"end":{"end":14.2272,"start":6.1772}},"probes":{"0.30":[{"t":2.58,"p":0.13117775321006775},{"t":2.68,"p":0.7040206789970398},{"t":2.74,"p":0.8971817493438721},{"t":3,"p":0.9403132200241089},{"t":3.32,"p":0.9647200703620911},{"t":3.38,"p":0.9768373966217041},{"t":3.7,"p":0.9842595458030701},{"t":3.84,"p":0.9842595458030701},{"t":3.86,"p":0.9842595458030701},{"t":4.28,"p":0.9842595458030701},{"t":4.44,"p":0.9842595458030701},{"t":4.66,"p":0.9842595458030701},{"t":6.42,"p":0.10281828045845032},{"t":6.52,"p":0.10281828045845032},{"t":6.66,"p":0.10281828045845032},{"t":6.84,"p":0.10281828045845032},{"t":6.92,"p":0.10281828045845032},{"t":7.32,"p":0.10281828045845032},{"t":7.38,"p":0.10281828045845032}]},"duration":14.22725,"events":[{"t":0.78,"kind":"speechStarted"},{"text":"add","t":1.28,"kind":"partial"},{"text":"add mil","t":1.38,"kind":"partial"},{"text":"add milk","t":1.44,"kind":"partial"},{"text":"add milk and","t":1.7,"kind":"partial"},{"text":"add milk and egg","t":2.02,"kind":"partial"},{"text":"add milk and eggs","t":2.08,"kind":"partial"},{"text":"add milk and eggs to","t":2.4,"kind":"partial"},{"text":"add milk and eggs to the","t":2.56,"kind":"partial"},{"text":"add milk and eggs to the shop","t":2.98,"kind":"partial"},{"text":"add milk and eggs to the shopping","t":3.14,"kind":"partial"},{"text":"add milk and eggs to the shopping list","t":3.36,"kind":"partial"},{"t":3.84,"kind":"speechEnded"},{"t":4.88,"kind":"speechStarted"},{"text":"add milk and eggs to the shopping list and","t":5.12,"kind":"partial"},{"text":"add milk and eggs to the shopping list and bread","t":5.22,"kind":"partial"},{"text":"add milk and eggs to the shopping list and bread if","t":5.54,"kind":"partial"},{"text":"add milk and eggs to the shopping list and bread if we're","t":6.02,"kind":"partial"},{"text":"add milk and eggs to the shopping list and bread if we're out","t":6.08,"kind":"partial"},{"text":"add milk and eggs to the shopping list and bread if we're out","t":6.66,"kind":"endOfUtterance"},{"t":6.92,"kind":"speechEnded"}],"id":"dev-Amina-pause-03@clean"}"#
}
