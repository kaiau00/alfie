import Foundation
import Testing
@testable import MoeVoice

struct WakeSpotterTests {

    let spotter = WakeSpotter(phrases: WakeSpotter.defaultPhrases)

    @Test func matchesThePhraseAtTheEnd() {
        let m = spotter.match(in: "so anyway hey alfie")
        #expect(m?.tail == "")
        #expect(m?.end == 19)
    }

    @Test func returnsTheRequestAfterThePhrase() {
        let m = spotter.match(in: "Hey Alfie, what's the weather like")
        #expect(m?.tail == "what's the weather like")
    }

    @Test func wholeWordsOnly() {
        #expect(spotter.match(in: "hey alfredo") == nil)
        #expect(spotter.match(in: "showalfie") == nil)
        #expect(spotter.match(in: "hey alfies") == nil)
        #expect(spotter.match(in: "hey alpha") == nil)
        #expect(spotter.match(in: "hey elfie") == nil)
    }

    @Test func caseInsensitive() {
        #expect(spotter.match(in: "HEY ALFIE") != nil)
    }

    @Test func onlyTheTailIsSearched() {
        let history = String(repeating: "blah ", count: 40)
        #expect(spotter.match(in: "hey alfie " + history) == nil)
        #expect(spotter.match(in: history + "hey alfie") != nil)
    }

    @Test func latestOfSeveralWins() {
        let m = spotter.match(in: "hey alfie no wait hey alfie stop")
        #expect(m?.tail == "stop")
    }

    @Test func singleWordPhrasesAreRefused() {
        let s = WakeSpotter(phrases: ["alfie", "hey alfie"])
        #expect(s.phrases == ["hey alfie"])
    }

    @Test func stripsALeadingPhraseFromTheAccurateRead() {
        #expect(spotter.strippingPhrase(from: "Hey Alfie, what time is it?") == "what time is it")
        #expect(spotter.strippingPhrase(from: "hey alfie") == "")
        #expect(spotter.strippingPhrase(from: "Hey Alfies is a band") == "Hey Alfies is a band")
        #expect(spotter.strippingPhrase(from: "what time is it, hey alfie") == "what time is it, hey alfie")
    }

    @Test func aWakeTurnIsCutAtTheLastMatch() {
        // The capture's pre-roll carries what came before the name.
        #expect(spotter.strippingPhrase(from: "see you later. Hey Alfie, what's the weather", anywhere: true) == "what's the weather")
        #expect(spotter.strippingPhrase(from: "hey alfie", anywhere: true) == "")
        #expect(spotter.strippingPhrase(from: "no phrase here", anywhere: true) == "no phrase here")
        #expect(spotter.strippingPhrase(from: "see you later. Hey Alfie, what's the weather") == "see you later. Hey Alfie, what's the weather")
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
        let m = spotter.match(in: "café ☕ hey alfie é")
        #expect(m?.tail == "é")
    }
}
