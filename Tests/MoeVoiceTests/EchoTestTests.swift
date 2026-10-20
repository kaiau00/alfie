import Foundation
import Testing
@testable import MoeVoice

struct EchoTestTests {

    @Test func aQuietMicrophoneIsClean() {
        // Built-in mic and speakers with the canceller working: barely
        // anything above the room's own noise.
        let leak = EchoTest.leakDb(floorRms: 0.004, spokenRms: 0.006)
        #expect(leak < 6)
        #expect(EchoTest.verdict(leakDb: leak, heardOwnWords: false) == .clean)
    }

    @Test func someLeakIsStillWorkable() {
        let leak = EchoTest.leakDb(floorRms: 0.004, spokenRms: 0.014)   // ~11 dB
        #expect(EchoTest.verdict(leakDb: leak, heardOwnWords: false) == .workable)
    }

    @Test func hearingItsOwnWordsIsLeakyWhateverTheLevel() {
        // A Bluetooth speaker beside a USB microphone: the canceller has
        // nothing to subtract, and the recogniser reads Moe back.
        #expect(EchoTest.verdict(leakDb: 3, heardOwnWords: true) == .leaky)
        #expect(EchoTest.verdict(leakDb: 25, heardOwnWords: false) == .leaky)
    }

    @Test func nothingPlayedIsNotAVerdictAboutTheMicrophone() {
        #expect(EchoTest.verdict(leakDb: 0, heardOwnWords: false, playedAnything: false) == .silent)
    }

    @Test func silenceDoesNotDivideByZero() {
        let leak = EchoTest.leakDb(floorRms: 0, spokenRms: 0)
        #expect(leak.isFinite)
    }

    @Test func everyVerdictSaysWhatToDo() {
        for verdict: EchoTest.Verdict in [.clean, .workable, .leaky, .silent, .unavailable("no microphone")] {
            let summary = EchoTest.summary(verdict)
            #expect(!summary.text.isEmpty, "\(verdict)")
            #expect(summary.text.count < 220, "\(verdict)")
        }
        #expect(EchoTest.summary(.clean).good)
        #expect(EchoTest.summary(.workable).good)
        #expect(!EchoTest.summary(.leaky).good)
    }
}
