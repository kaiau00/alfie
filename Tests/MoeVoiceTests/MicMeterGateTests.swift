import Foundation
import Testing
@testable import MoeVoice

/// The meter gate, held to what it publishes rather than to whether it ran.
///
/// A gate that never fired and a gate that allowed everything look identical
/// from outside, so every test here replays a run of readings and counts the
/// publishes. None of them asks `next` one question.
struct MicMeterGateTests {

    /// One second of the real thing: the pipeline offers a reading roughly
    /// every 64 ms — about sixteen a second — and never stops while the
    /// audio graph is up, which is always.
    static let perSecond = 16

    /// Replays readings exactly as `Conductor` does, feeding each result
    /// back as `current`, and returns what reached the UI.
    private func publishes(_ readings: [Float], listening: Bool, muted: Bool = false,
                           from start: Float = 0) -> [Float] {
        var current = start
        var out: [Float] = []
        for r in readings {
            if let next = MicMeterGate.next(reading: r, listening: listening, muted: muted,
                                            current: current) {
                current = next
                out.append(next)
            }
        }
        return out
    }

    /// A room with someone typing in it — what an idle Moe hears all day.
    /// Seeded, so a failure is reproducible.
    private func roomNoise(_ n: Int) -> [Float] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        return (0..<n).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24) * 0.45
        }
    }

    /// The case that was the largest single item in a CPU profile of an idle
    /// Moe: nobody is listening, so nothing renders the number, so nothing
    /// may be published — not once in an hour.
    @Test func anIdleHourPublishesNothing() {
        let hour = Self.perSecond * 60 * 60
        let out = publishes(roomNoise(hour), listening: false)
        #expect(out.count == 0)
    }

    /// The meter must still fall to zero when the microphone closes — a halo
    /// frozen at the last level is a bug, not an optimisation — and then go
    /// quiet. This is the half `@Published`'s lack of de-duplication gets
    /// wrong on its own.
    @Test func goingQuietPublishesZeroOnceThenStops() {
        let first = MicMeterGate.next(reading: 0.6, listening: false, current: 0.6)
        #expect(first == 0)

        let after = publishes(roomNoise(Self.perSecond * 60), listening: false, from: first ?? 0)
        #expect(after.count == 0)
    }

    /// A gate that silences the thing it guards is not a fix: while
    /// listening, a voice has to drive the meter.
    @Test func listeningStillPublishesTheMeter() {
        let speech = (0..<Self.perSecond).map { Float(0.5 + 0.4 * sin(Double($0) / 3)) }
        let out = publishes(speech, listening: true)
        #expect(out.count > Self.perSecond / 2)
    }

    /// The step, from both sides at once: coarse enough to swallow the float
    /// noise a live microphone makes in a silent room, fine enough that a
    /// real voice is not quantised. A hundredth of the range is a fifteenth
    /// of a point on the halo's 7 pt spread.
    @Test func theStepIsBelowWhatTheHaloShowsAndAboveFloatNoise() {
        #expect(MicMeterGate.step == 0.01)

        // A live microphone in a silent room, a minute of it: below the
        // step, so it never leaves zero and never publishes.
        let noise = (0..<(Self.perSecond * 60)).map { _ in Float(0.004) }
        #expect(publishes(noise, listening: true).count == 0)

        #expect(MicMeterGate.next(reading: 0.01, listening: true, current: 0) == 0.01)
        #expect(MicMeterGate.next(reading: 0.009, listening: true, current: 0) == nil)
    }

    /// Revert the gate and this suite must go red, or it is decoration.
    /// Written down: the old line was `self.level = l`, which publishes on
    /// every reading, and `anIdleHourPublishesNothing` is what catches its
    /// return.
    @Test func theUngatedBehaviourWouldFailTheIdleTest() {
        let minute = Self.perSecond * 60
        let readings = roomNoise(minute)
        let ungated = readings.count            // what `self.level = l` publishes
        let gated = publishes(readings, listening: false).count
        #expect(gated == 0)
        #expect(ungated - gated == minute)
    }

    /// The owner, 2026-09-25: muted, the island still pulsed with his voice.
    /// Muted and listening (the follow-up window), a minute of loud speech
    /// reaches the UI as nothing at all; a meter caught mid-word when the
    /// mute lands falls to zero once and stays there.
    @Test func mutedTheUIIsHandedNothingOfTheVoice() {
        let speech = (0..<(Self.perSecond * 60)).map { Float(0.6 + 0.35 * sin(Double($0) / 3)) }
        #expect(publishes(speech, listening: true, muted: true).isEmpty)
        let caught = publishes(speech, listening: true, muted: true, from: 0.8)
        #expect(caught == [0])
        // Control: the same speech unmuted does drive it.
        #expect(!publishes(speech, listening: true).isEmpty)
    }
}
