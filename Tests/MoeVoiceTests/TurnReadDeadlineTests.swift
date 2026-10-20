import Foundation
import Testing
@testable import MoeVoice

/// The turn's patience with its own re-read.
///
/// The incident is written out in `TurnReadDeadline`: a 59.6 s dictation
/// dropped on 2026-09-09 because the turn's flat 30 s deadline was tighter
/// than the 51.7 s the AssemblyAI session had already given itself, and the
/// cloud's correct transcript arrived 14 s after the turn had been thrown
/// away.
///
/// The first test is the one that matters, and it is deliberately not
/// written against a number typed twice: it asks a real `AssemblyAIStream`
/// what *it* would wait, and requires this deadline to be longer. Change
/// either side and it goes red.
struct TurnReadDeadlineTests {

    /// A stream with the shipping defaults. No socket is opened: only its
    /// own arithmetic is asked for.
    private func stream() -> AssemblyAIStream {
        AssemblyAIStream(factory: NeverConnects(),
                         connection: { throw CancellationError() })
    }

    /// **The guard.** Across every plausible utterance length, the turn
    /// waits longer than the backend does — so the backend's own failure
    /// path runs, and this deadline only ever fires for something truly
    /// wedged.
    @Test func deadlineIsLooserThanTheBackendsOwn() async {
        let s = stream()
        for audio in stride(from: 0.5, through: 300, by: 0.5) {
            let backend = await s.batchDeadline(forSeconds: audio)
            let turn = TurnReadDeadline.seconds(forAudioSeconds: audio)
            #expect(turn > backend,
                    "at \(audio) s of audio the turn gives up after \(turn) s but the backend is still allowed \(backend) s — the turn would discard an answer that is coming")
        }
    }

    /// The exact audio from the incident, with the exact measured timings.
    /// The read came back at 43.6 s; the turn must still have been waiting.
    @Test func theDictationThatWasLostWouldNowSurvive() {
        let measured = 43.636
        #expect(TurnReadDeadline.seconds(forAudioSeconds: 59.6) > measured,
                "the 2026-09-09 dictation would be dropped again")
    }

    /// A flat 30 s — what shipped — fails the case above. Without this the
    /// suite could pass on a deadline that never changed.
    @Test func theOldFlatDeadlineWouldHaveFailed() {
        #expect(TurnReadDeadline.floorSeconds < 43.636)
        #expect(TurnReadDeadline.seconds(forAudioSeconds: 59.6) > 30)
    }

    /// A short turn keeps the old floor: a cold local model gets its 30 s.
    @Test func shortTurnsKeepTheFloor() {
        #expect(TurnReadDeadline.seconds(forAudioSeconds: 0) == 30)
        #expect(TurnReadDeadline.seconds(forAudioSeconds: 3) == 30)
    }

    /// It grows without bound rather than clamping: a five-minute
    /// dictation is a thing people do, and a ceiling would recreate the bug
    /// at whatever length the ceiling sat.
    @Test func itKeepsGrowingWithTheAudio() {
        let a = TurnReadDeadline.seconds(forAudioSeconds: 120)
        let b = TurnReadDeadline.seconds(forAudioSeconds: 300)
        #expect(b > a)
        #expect(a > 120)
    }
}

/// A factory that never yields a socket. These tests ask the actor only for
/// arithmetic, so connecting must never be attempted.
private struct NeverConnects: AssemblyAISocketFactory {
    func connect(url: URL, authorization: String?) async throws -> any AssemblyAISocket {
        throw CancellationError()
    }
}
