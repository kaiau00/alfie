import Foundation
import Testing
import MoeIsland
import MoeVoice
@testable import Moe

/// "Double-tap ⌥ always means stop", driven through the real Conductor with
/// the talk key's real grammar (`TalkChordMachine`) in front of it, wired the
/// way `PushToTalk` and `AppDelegate` wire them.
@MainActor
@Suite(.serialized)
struct HardStopTests {

    /// What PushToTalk does with the machine's actions, minus the timers.
    @MainActor private struct Key {
        var chord = TalkChordMachine()
        let moe: Conductor

        mutating func send(_ event: TalkChordMachine.Event) {
            run(chord.handle(event))
        }

        private mutating func run(_ actions: [TalkChordMachine.Action]) {
            for action in actions {
                switch action {
                case .press: moe.holdBegan()
                case .release: moe.holdEnded()
                case .tap: moe.holdEnded(tap: true)
                case .doubleTap:
                    let latched = moe.talkLatchAllowed() ? chord.handle(.latch) : []
                    if latched.isEmpty { moe.stopEverything() } else { run(latched) }
                case .latch: moe.talkLatchBegan()
                case .unlatch(let reason): moe.talkLatchEnded(reason)
                case .cancel: moe.holdCancelled()
                case .holdConfirmed: moe.holdConfirmed()
                case .armTapWindow, .disarmTapWindow: break
                }
            }
        }
    }

    private func make() throws -> (Conductor, FakeBrain) {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.voice.holdsWithoutAudioForTests = true
        return (moe, brain)
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 60_000_000) }

    private func atRest(_ s: VoiceEngine.State) -> Bool { s == .off || s == .standby }

    /// moe.log, 2026-10-13 13:40:13–15. "Hey Moe" fired by mistake
    /// (`standby → capturing(wake)`); the owner double-tapped to make it go
    /// away. It latched hands-free instead — the voice was "listening" — and
    /// the next tap sent "One of my emails as an operator to the ISTA admin"
    /// to the brain; only a third double-tap stopped it. One double-tap is
    /// one stop now.
    @Test func theThirteenFortyDoubleTapIsOneStop() async throws {
        let (moe, brain) = try make()
        moe.voice.driveMachineForTests([.setWake(true), .woke])
        #expect(moe.voice.state == .capturing(.wake))
        #expect(moe.mode == .listening)

        var key = Key(moe: moe)
        key.send(.down(0));    try await settle()     // hold began; capturing(wake) → capturing(hold)
        key.send(.up(0.10))
        key.send(.down(0.20))
        key.send(.up(0.30));   try await settle()     // the double-tap

        #expect(!moe.talkLatched, "the double-tap latched hands-free")
        #expect(atRest(moe.voice.state), "still \(moe.voice.state)")
        #expect(moe.mode == .idle)
        #expect(moe.showingStopped, "the stop did not say so")

        // The tap that used to send, 0.6 s later: a fresh press from rest.
        key.send(.down(0.9)); key.send(.up(0.98)); key.send(.tapWindowClosed)
        try await settle()
        #expect(brain.sent.isEmpty, "a turn reached the brain: \(brain.sent)")
        #expect(!moe.turns.contains { $0.role == .you })
        #expect(atRest(moe.voice.state))
    }

    /// From true rest the double-tap is still "listen hands-free" — and a
    /// tap straight after it undoes the latch instead of sending.
    @Test func fromRestALatchThenAQuickTapSendsNothing() async throws {
        let (moe, brain) = try make()
        moe.voice.driveMachineForTests([.setWake(true)])
        #expect(moe.voice.state == .standby)

        var key = Key(moe: moe)
        for e: TalkChordMachine.Event in [.down(0), .up(0.10), .down(0.20), .up(0.30)] { key.send(e) }
        try await settle()
        #expect(moe.talkLatched)
        #expect(moe.voice.state == .capturing(.hold))
        #expect(moe.mode == .listening)

        key.send(.down(0.8)); key.send(.up(0.86))
        try await settle()
        #expect(!moe.talkLatched)
        #expect(atRest(moe.voice.state), "still \(moe.voice.state)")
        #expect(brain.sent.isEmpty)
        #expect(moe.showingStopped)
    }

    /// The first tap from rest shows nothing: no island, no `.listening`,
    /// no hold reaches the voice. Only a press that outlasts a tap does.
    @Test func aTapFromRestShowsNothing() async throws {
        let (moe, _) = try make()
        moe.voice.driveMachineForTests([.setWake(true)])
        var shown = 0
        moe.onWantsIsland = { if $0 { shown += 1 } }

        var key = Key(moe: moe)
        key.send(.down(0))
        #expect(moe.mode == .idle)
        key.send(.up(0.1)); key.send(.tapWindowClosed)
        try await settle()
        #expect(shown == 0, "the island lit for a tap")
        #expect(moe.mode == .idle)
        #expect(!moe.voice.fedForTests.contains(.holdDown))
        #expect(moe.voice.state == .standby)

        // A hold: shown once the threshold says so, not before.
        key.send(.down(5))
        #expect(shown == 0)
        key.send(.holdThreshold(5.22)); try await settle()
        #expect(shown == 1)
        #expect(moe.mode == .listening)
        #expect(moe.voice.state == .capturing(.hold))
    }

    /// Esc in Moe's own windows stops — not over a hands-free turn or a
    /// dictation, which have their own Esc, and not with nothing going on.
    @Test func escStopsOnlyWithSomethingToStop() {
        #expect(Conductor.escStops(talkLatched: false, dictating: false, somethingToStop: true))
        #expect(!Conductor.escStops(talkLatched: false, dictating: false, somethingToStop: false))
        #expect(!Conductor.escStops(talkLatched: true, dictating: false, somethingToStop: true))
        #expect(!Conductor.escStops(talkLatched: false, dictating: true, somethingToStop: true))
    }

    @Test func theStopReceiptNamesEachPart() {
        typealias R = StopReceipt
        #expect(R.line([.ttsSilent: .after(ms: 3), .captureClosed: .after(ms: 41),
                        .brainAbandoned: .after(ms: 2)])
                == "stop: tts silent +3ms, capture closed +41ms, brain abandoned +2ms")
        #expect(R.line([.ttsSilent: .notApplicable, .captureClosed: .after(ms: 9),
                        .brainAbandoned: .notApplicable])
                == "stop: tts was silent, capture closed +9ms, brain was idle")
        #expect(R.line([:]).contains("brain abandoned: no answer"))
    }

    @Test func theReceiptIsWrittenOnceAllThreeAreIn() async {
        var lines: [String] = []
        let began = Date()
        let r = StopReceipt(began: began) { lines.append($0) }
        r.mark(.ttsSilent, applies: true, at: began.addingTimeInterval(0.004))
        r.mark(.captureClosed, applies: false)
        #expect(lines.isEmpty)
        r.mark(.brainAbandoned, applies: true, at: began.addingTimeInterval(0.010))
        #expect(lines == ["stop: tts silent +4ms, capture was closed, brain abandoned +10ms"])
        r.mark(.brainAbandoned, applies: true)
        #expect(lines.count == 1)
    }

    @Test func stoppedOutranksEveryLeftEarForItsMoment() {
        var i = IslandEars.Inputs()
        i.stopped = true
        i.recording = true
        i.muted = true
        i.listening = true
        #expect(IslandEars.of(i).left == .stopped)
        i.stopped = false
        #expect(IslandEars.of(i).left == .recording(paused: false, whisper: false))
    }
}
