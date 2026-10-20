import Foundation
import Testing
@testable import MoeVoice

struct WakeSpotterTests {

    let spotter = WakeSpotter(phrases: WakeSpotter.defaultPhrases)

    @Test func matchesThePhraseAtTheEnd() {
        let m = spotter.match(in: "so anyway hey moe")
        #expect(m?.tail == "")
        #expect(m?.end == 17)
    }

    @Test func returnsTheRequestAfterThePhrase() {
        let m = spotter.match(in: "Hey Moe, what's the weather like")
        #expect(m?.tail == "what's the weather like")
    }

    @Test func wholeWordsOnly() {
        #expect(spotter.match(in: "hey mobile") == nil)
        #expect(spotter.match(in: "showmoe") == nil)
        #expect(spotter.match(in: "hey moebius") == nil)
        #expect(spotter.match(in: "hey mom") == nil)
        #expect(spotter.match(in: "hey more") == nil)
    }

    @Test func caseInsensitive() {
        #expect(spotter.match(in: "HEY MOE") != nil)
    }

    @Test func onlyTheTailIsSearched() {
        let history = String(repeating: "blah ", count: 40)
        #expect(spotter.match(in: "hey moe " + history) == nil)
        #expect(spotter.match(in: history + "hey moe") != nil)
    }

    @Test func latestOfSeveralWins() {
        let m = spotter.match(in: "hey moe no wait hey moe stop")
        #expect(m?.tail == "stop")
    }

    @Test func singleWordPhrasesAreRefused() {
        let s = WakeSpotter(phrases: ["moe", "hey moe"])
        #expect(s.phrases == ["hey moe"])
    }

    @Test func stripsALeadingPhraseFromTheAccurateRead() {
        #expect(spotter.strippingPhrase(from: "Hey Moe, what time is it?") == "what time is it")
        #expect(spotter.strippingPhrase(from: "hey moe") == "")
        #expect(spotter.strippingPhrase(from: "Hey Moebius is a band") == "Hey Moebius is a band")
        #expect(spotter.strippingPhrase(from: "what time is it, hey moe") == "what time is it, hey moe")
    }

    @Test func aWakeTurnIsCutAtTheLastMatch() {
        // The capture's pre-roll carries what came before the name.
        #expect(spotter.strippingPhrase(from: "see you later. Hey Moe, what's the weather", anywhere: true) == "what's the weather")
        #expect(spotter.strippingPhrase(from: "hey moe", anywhere: true) == "")
        #expect(spotter.strippingPhrase(from: "no phrase here", anywhere: true) == "no phrase here")
        #expect(spotter.strippingPhrase(from: "see you later. Hey Moe, what's the weather") == "see you later. Hey Moe, what's the weather")
    }

    @Test func aMisheardNameIsStrippedFromAWakeTurn() {
        // The head heard "Hey Moe"; the recogniser wrote something else.
        // Measured on this Mac: "Hey man", "hemo", "High night", "Hey Mo".
        #expect(spotter.strippingPhrase(from: "Hey man, what's the weather", anywhere: true) == "what's the weather")
        #expect(spotter.strippingPhrase(from: "Hemo, what time is it", anywhere: true) == "what time is it")
        #expect(spotter.strippingPhrase(from: "Hey Mo. Read my messages", anywhere: true) == "Read my messages")
        #expect(spotter.strippingPhrase(from: "Hey man", anywhere: true) == "")
    }

    /// 2026-09-29 20:40:44 and 20:41:06: "Hey Moe" came back as "Emma?",
    /// and Moe answered "I'm Moe, not Emma". A bare "Hey," five times.
    @Test func theNameHeardAsAnotherWordIsStrippedToo() {
        #expect(spotter.strippingPhrase(from: "Emma? What happened to our subagents? Are they all running", anywhere: true)
                == "What happened to our subagents? Are they all running")
        #expect(spotter.strippingPhrase(from: "Emma? Why do you say that? Are you sure", anywhere: true)
                == "Why do you say that? Are you sure")
        #expect(spotter.strippingPhrase(from: "Hey, what's on my calendar today", anywhere: true)
                == "what's on my calendar today")
        #expect(spotter.strippingPhrase(from: "Emma", anywhere: true) == "")
        // Not on a turn the name did not open.
        #expect(spotter.strippingPhrase(from: "Emma? What happened") == "Emma? What happened")
    }

    @Test func aRealRequestIsNeverEaten() {
        // Words that start like the name but open a request.
        for request in ["make a note", "my calendar for tomorrow", "more detail please",
                        "what's the weather", "remind me at five"] {
            #expect(spotter.strippingPhrase(from: request, anywhere: true) == request, "\(request)")
        }
        // And without a wake turn, nothing is guessed at.
        #expect(spotter.strippingPhrase(from: "Hey man, what's the weather") == "Hey man, what's the weather")
    }

    @Test func unicodeSafeOffsets() {
        let m = spotter.match(in: "café ☕ hey moe é")
        #expect(m?.tail == "é")
    }
}
