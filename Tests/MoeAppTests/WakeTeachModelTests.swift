import Foundation
import Testing
import MoeVoice
@testable import Moe

/// The teach card's controller against a fake microphone: which clip files
/// it deletes, and whether it gives the microphone back. The flow decides;
/// these check that what it decided is what happened on disk.
@MainActor
struct WakeTeachModelTests {

    /// Records what it was asked; each `record` waits until the test
    /// answers it.
    @MainActor
    final class FakeDriver: WakeTeachDriving {
        var opened = 0, closed = 0
        var deleted: [URL] = []
        var pending: CheckedContinuation<(WakeTeachFlow.ClipResult, URL?)?, Never>?
        var recordedLines: [Int] = []

        func open(level: @escaping @MainActor (Float) -> Void) async -> WakeTeachFlow.Failure? {
            opened += 1; level(0.5); return nil
        }
        func record(line: Int, session: String,
                    onSpeech: @escaping @MainActor () -> Void) async -> (WakeTeachFlow.ClipResult, URL?)? {
            recordedLines.append(line)
            return await withCheckedContinuation { pending = $0 }
        }
        func answer(_ r: (WakeTeachFlow.ClipResult, URL?)?) {
            let c = pending; pending = nil; c?.resume(returning: r)
        }
        func delete(_ url: URL) { deleted.append(url) }
        func close() { closed += 1 }
        func measure(progress: @escaping @MainActor (Int, Int) -> Void) async
            -> Result<WakeTeachFlow.Outcome, WakeTeachFlow.Failure> {
            progress(1, 1)
            return .failure(.heardNothing)
        }
    }

    func settle(_ until: @MainActor () -> Bool) async {
        for _ in 0..<200 where !until() { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    func url(_ n: Int) -> URL { URL(fileURLWithPath: "/tmp/teach-\(n).wav") }

    @Test func aClipSavedAfterAPauseIsDeletedNotKept() async {
        let fake = FakeDriver()
        let model = WakeTeachModel(driver: fake)
        model.send(.start)
        await settle { fake.pending != nil }
        #expect(fake.opened == 1)
        #expect(model.level == 0.5)
        model.send(.pause)
        #expect(fake.closed == 1)
        // The take was already saving when the pause came.
        fake.answer((.kept, url(1)))
        await settle { !fake.deleted.isEmpty }
        #expect(fake.deleted == [url(1)])
        #expect(model.files.isEmpty)
        #expect(model.flow.step == .paused(0))
    }

    @Test func cancelMidwayDeletesWhatThisRunKeptAndClosesTheMicrophone() async {
        let fake = FakeDriver()
        let model = WakeTeachModel(driver: fake)
        model.beatSeconds = 0
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.send(.start)
        await settle { fake.pending != nil }
        fake.answer((.kept, url(1)))
        // The beat passes and line 1 is being recorded.
        await settle { fake.recordedLines == [0, 1] && fake.pending != nil }
        #expect(model.files == [0: url(1)])
        model.send(.cancel)
        #expect(dismissed)
        #expect(fake.closed == 1)
        #expect(fake.deleted == [url(1)])
        fake.answer(nil)
    }

    @Test func aRejectedClipWaitsAndTheRetakeRecordsTheSameLine() async {
        let fake = FakeDriver()
        let model = WakeTeachModel(driver: fake)
        model.send(.start)
        await settle { fake.pending != nil }
        fake.answer((.rejected(.nothingHeard), nil))
        await settle { model.flow.step == .retake(0, .nothingHeard) }
        #expect(model.flow.step == .retake(0, .nothingHeard))
        model.send(.retake)
        await settle { fake.pending != nil }
        #expect(fake.recordedLines == [0, 0])
        fake.answer(nil)
    }

    /// A quiet clip is kept: its file is the card's, and the card moves on
    /// to the next line by itself — it does not wait for a retake.
    @Test func aQuietClipIsKeptAndTheCardMovesOn() async {
        let fake = FakeDriver()
        let model = WakeTeachModel(driver: fake)
        model.beatSeconds = 0
        model.send(.start)
        await settle { fake.pending != nil }
        fake.answer((.keptQuiet, url(1)))
        await settle { fake.recordedLines == [0, 1] && fake.pending != nil }
        #expect(model.files == [0: url(1)])
        #expect(model.flow.kept[0])
        #expect(model.flow.step == .listening(1))
        #expect(fake.deleted.isEmpty)
        fake.answer(nil)
    }
}
