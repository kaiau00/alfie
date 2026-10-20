import Foundation
import Testing
@testable import MoeVoice

/// Item 4 of the 2026-09-22 voice audit: the VAD's onsets, held to the
/// room's own level. Silero said "speech" to audio the capture later
/// measured as "0.00 of the opening level".
struct NoiseFloorGateTests {

    /// A room at `db`, heard for `n` chunks with the VAD quiet.
    private func room(_ g: inout NoiseFloorGate, _ db: Float, _ n: Int = 20) {
        for _ in 0..<n { _ = g.observe(chunkDb: db, peakDb: db + 1, vad: nil) }
    }

    @Test func theFloorIsTheRoom() {
        var g = NoiseFloorGate()
        #expect(g.floorDb == nil)
        room(&g, -50)
        #expect(g.floorDb.map { abs($0 - -50) < 0.5 } == true)
    }

    @Test func beforeTheFloorIsKnownEdgesPassThrough() {
        var g = NoiseFloorGate()
        #expect(g.observe(chunkDb: -60, peakDb: -59, vad: .start) == .started)
        #expect(g.observe(chunkDb: -60, peakDb: -59, vad: .end) == .ended)
    }

    @Test func aVoiceWellOverTheRoomIsSpeech() {
        var g = NoiseFloorGate()
        room(&g, -50)
        #expect(g.observe(chunkDb: -30, peakDb: -25, vad: .start) == .started)
        #expect(g.observe(chunkDb: -32, peakDb: -26, vad: nil) == nil)
        #expect(g.observe(chunkDb: -50, peakDb: -49, vad: .end) == .ended)
    }

    /// The fan the VAD calls speech: no louder than the room, so no onset.
    @Test func speechShapedSoundAtTheRoomsLevelIsNotAnOnset() {
        var g = NoiseFloorGate()
        room(&g, -40)
        #expect(g.observe(chunkDb: -40, peakDb: -38, vad: .start) == nil)
        #expect(g.refusedOnsets == 1)
        #expect(!g.inSpeech)
        // The VAD ending it reports nothing: nothing was started.
        #expect(g.observe(chunkDb: -40, peakDb: -38, vad: .end) == nil)
    }

    /// Someone starts talking over the fan the VAD was already calling
    /// speech: the onset comes when the voice rises clear of the room.
    @Test func aVoiceRisingOutOfTheNoiseStartsThere() {
        var g = NoiseFloorGate()
        room(&g, -40)
        #expect(g.observe(chunkDb: -40, peakDb: -38, vad: .start) == nil)
        #expect(g.observe(chunkDb: -40, peakDb: -39, vad: nil) == nil)
        #expect(g.observe(chunkDb: -28, peakDb: -22, vad: nil) == .started)
    }

    /// The failure-2 mechanism: steady noise keeps the VAD in speech after
    /// the person stops, so no pause is ever reported. Once the level has
    /// sat on the floor for three chunks the speech is over.
    @Test func speechEndsWhenTheLevelReturnsToTheRoomEvenIfTheVadDoesNot() {
        var g = NoiseFloorGate()
        room(&g, -40)
        #expect(g.observe(chunkDb: -25, peakDb: -20, vad: .start) == .started)
        #expect(g.observe(chunkDb: -26, peakDb: -21, vad: nil) == nil)
        // The person stops; the fan goes on and the VAD stays "in speech".
        #expect(g.observe(chunkDb: -40, peakDb: -39, vad: nil) == nil)
        #expect(g.observe(chunkDb: -40, peakDb: -38.5, vad: nil) == nil)
        #expect(g.observe(chunkDb: -40, peakDb: -39, vad: nil) == .ended)
        #expect(g.vadInSpeech)
        // …and if they start again, that is a new onset.
        #expect(g.observe(chunkDb: -24, peakDb: -19, vad: nil) == .started)
    }

    /// A pause inside a sentence is not three chunks at the floor with a
    /// voice either side of it: one quiet chunk changes nothing.
    @Test func aShortDipDoesNotEndSpeech() {
        var g = NoiseFloorGate()
        room(&g, -45)
        _ = g.observe(chunkDb: -25, peakDb: -20, vad: .start)
        #expect(g.observe(chunkDb: -45, peakDb: -44, vad: nil) == nil)
        #expect(g.observe(chunkDb: -26, peakDb: -21, vad: nil) == nil)
        #expect(g.inSpeech)
    }

    /// Talking for the whole window still leaves the floor on the room.
    @Test func aLongTurnDoesNotRaiseTheFloorToTheVoice() {
        var g = NoiseFloorGate()
        room(&g, -50, 12)
        _ = g.observe(chunkDb: -25, peakDb: -20, vad: .start)
        for i in 0..<60 {
            // Speech with a breath every fifth chunk.
            let db: Float = i % 5 == 0 ? -50 : -25
            _ = g.observe(chunkDb: db, peakDb: db + 4, vad: nil)
        }
        #expect((g.floorDb ?? 0) < -45)
    }

    /// Fifteen seconds of fluent speech with no breath the gate can see:
    /// the floor stays the room's (review L3).
    @Test func unbrokenSpeechDoesNotTeachTheFloor() {
        var g = NoiseFloorGate()
        room(&g, -50, 12)
        _ = g.observe(chunkDb: -25, peakDb: -20, vad: .start)
        for _ in 0..<80 { _ = g.observe(chunkDb: -25, peakDb: -20, vad: nil) }
        #expect((g.floorDb ?? 0) < -45)
        #expect(g.inSpeech)
    }

    @Test func levelsReadMeanAndPeak() {
        let quiet = [Float](repeating: 0.001, count: 3584)
        let loud = [Float](repeating: 0.1, count: 512)
        let l = NoiseFloorGate.levels(quiet + loud)
        #expect(abs(l.peakDb - -20) < 0.1)
        #expect(l.meanDb < l.peakDb)
    }
}
