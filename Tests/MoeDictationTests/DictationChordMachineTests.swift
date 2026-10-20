import Foundation
import Testing
@testable import MoeDictation

struct DictationChordMachineTests {

    typealias M = DictationChordMachine
    typealias A = M.Action

    /// Feed a script, collecting every action in order.
    private func run(_ events: [M.Event], into m: inout M) -> [A] {
        events.flatMap { m.handle($0) }
    }

    // MARK: Hold-to-talk, unchanged

    @Test func holdBeginsOnDownAndEndsOnUp() {
        var m = M()
        #expect(m.handle(.down(0)) == [.begin])
        #expect(m.isActive)
        #expect(m.handle(.up(1.5)) == [.end])
        #expect(m.phase == .idle)
    }

    @Test func singleTapStillBeginsAndEnds() {
        var m = M()
        #expect(run([.down(0), .up(0.08)], into: &m) == [.begin, .end])
        #expect(!m.isLatched)
    }

    @Test func otherKeyWhileHeldCancels() {
        var m = M()
        #expect(run([.down(0), .otherKey], into: &m) == [.begin, .cancel])
        // The release that follows finds nothing down.
        #expect(m.handle(.up(0.3)) == [])
    }

    @Test func escWhileHeldCancels() {
        var m = M()
        #expect(run([.down(0), .esc], into: &m) == [.begin, .cancel])
    }

    @Test func downTwiceWithoutUpIsIgnored() {
        var m = M()
        #expect(run([.down(0), .down(0.05)], into: &m) == [.begin])
    }

    // MARK: Latching

    @Test func doubleTapLatches() {
        var m = M()
        let actions = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        #expect(actions == [.begin, .end, .begin, .latch])
        #expect(m.isLatched)
        #expect(m.latchDeadline == 0.28 + 180)
    }

    @Test func tapWhileLatchedEndsAndPastes() {
        var m = M()
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        #expect(run([.down(5), .up(5.06)], into: &m) == [.unlatch(.tap), .end])
        #expect(m.phase == .idle)
    }

    @Test func holdAndReleaseWhileLatchedEndsToo() {
        var m = M()
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        #expect(m.handle(.down(5)) == [])        // nothing begins: already recording
        #expect(m.handle(.up(7)) == [.unlatch(.tap), .end])
    }

    @Test func escWhileLatchedCancels() {
        var m = M()
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        #expect(m.handle(.esc) == [.unlatch(.esc), .cancel])
        #expect(!m.isActive)
    }

    @Test func escWhileLatchedKeyDownCancelsAndReleaseIsIgnored() {
        var m = M()
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28), .down(3)], into: &m)
        #expect(m.handle(.esc) == [.unlatch(.esc), .cancel])
        #expect(m.handle(.up(3.1)) == [])
    }

    @Test func otherKeysDoNotCancelWhileLatched() {
        var m = M()
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        #expect(run([.otherKey, .otherKey, .otherKey], into: &m) == [])
        #expect(m.isLatched)
    }

    @Test func shortcutWhileLatchedKeyDownNeitherCancelsNorEnds() {
        // ⌘Tab while hands-free: the ⌘ release is not the finishing tap.
        var m = M()
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28), .down(3)], into: &m)
        #expect(m.handle(.otherKey) == [])
        #expect(m.handle(.up(3.05)) == [])
        #expect(m.isLatched)
        #expect(m.latchDeadline == 0.28 + 180)
        // The next plain tap still finishes it.
        #expect(run([.down(4), .up(4.05)], into: &m) == [.unlatch(.tap), .end])
    }

    // MARK: Invariants under random input

    /// Whatever the key does, recordings pair up: never two `begin`s without
    /// an `end`/`cancel` between, never an `end`/`cancel` with nothing begun,
    /// `latch` only right after two short taps inside the window (and only
    /// while a recording is running), and `unlatch` only while latched.
    @Test func randomSequencesKeepRecordingsPaired() {
        var rng = SplitMix(seed: 0x5EED)
        for _ in 0..<2_000 {
            var m = M(tapThreshold: 0.22, doubleTapWindow: 0.35, latchTimeout: 5)
            var t = 0.0
            var keyDown = false
            var recording = false
            var latched = false
            var tapUps: [Double] = []      // release times of short taps
            var lastDown = 0.0
            for _ in 0..<40 {
                t += [0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 2, 6][Int(rng.next() % 8)]
                let e: M.Event
                switch rng.next() % 7 {
                case 0, 1: e = .down(t)
                case 2, 3: e = .up(t)
                case 4:    e = .otherKey
                case 5:    e = rng.next() % 2 == 0 ? .esc : .lock
                default:   e = .tick(t)
                }
                let before = m
                let actions = m.handle(e)
                for a in actions {
                    switch a {
                    case .begin:
                        #expect(!recording, "begin while recording after \(e) in \(before)")
                        recording = true
                    case .end, .cancel:
                        #expect(recording, "\(a) with nothing begun after \(e)")
                        recording = false
                        latched = false
                    case .latch:
                        #expect(recording && !latched, "latch out of place after \(e)")
                        // Two short taps, release to release, inside the window.
                        if case .up(let now) = e {
                            #expect(now - lastDown < 0.22)
                            #expect(tapUps.last.map { now - $0 < 0.35 } == true,
                                    "latch without a paired tap at \(now): \(tapUps)")
                        } else {
                            Issue.record("latch on \(e)")
                        }
                        latched = true
                    case .unlatch:
                        #expect(latched, "unlatch while not latched after \(e)")
                        #expect(actions.last == .end || actions.last == .cancel)
                    }
                }
                // Model the taps for the latch check. A down only counts
                // when the machine could take it (`PushToTalk` never sends
                // two downs without an up between, but Esc while held
                // leaves the key physically down with the machine idle).
                if case .down(let now) = e {
                    switch before.phase {
                    case .idle, .latched: keyDown = true; lastDown = now
                    case .held, .latchedKeyDown: break
                    }
                }
                if case .up(let now) = e, keyDown {
                    keyDown = false
                    if now - lastDown < 0.22 { tapUps.append(now) }
                }
                #expect(m.isActive == recording, "phase \(m.phase) vs recording=\(recording) after \(e)")
                #expect(m.isLatched == latched)
                if !latched {
                    #expect(m.latchDeadline == nil)
                }
            }
        }
    }

    @Test func nonsenseWhenIdleIsSilent() {
        var m = M()
        #expect(run([.up(0), .up(1), .otherKey, .esc, .lock, .tick(999), .tick(-1)], into: &m) == [])
        #expect(m.phase == .idle)
        #expect(m.handle(.down(2)) == [.begin])
    }

    @Test func tickBeforeTheDeadlineWhileKeyDownDoesNothing() {
        var m = M(latchTimeout: 10)
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28), .down(5)], into: &m)
        #expect(m.handle(.tick(10.27)) == [])
        #expect(m.phase == .latchedKeyDown(since: 0.28))
    }

    @Test func tapTapHoldDoesNotStack() {
        // Tap, tap (latched), then a long hold: the hold's release ends the
        // run; it never begins a second recording or re-latches.
        var m = M()
        let actions = run([.down(0), .up(0.08), .down(0.20), .up(0.28),
                           .down(0.40), .up(2.0)], into: &m)
        #expect(actions == [.begin, .end, .begin, .latch, .unlatch(.tap), .end])
        #expect(m.phase == .idle)
    }

    @Test func tripleTapLatchesThenEnds() {
        var m = M()
        let actions = run([.down(0), .up(0.08),
                           .down(0.20), .up(0.28),
                           .down(0.40), .up(0.48)], into: &m)
        #expect(actions == [.begin, .end, .begin, .latch, .unlatch(.tap), .end])
        // And a fourth tap is a plain first tap, not the second of a pair.
        #expect(run([.down(0.6), .up(0.68)], into: &m) == [.begin, .end])
        #expect(!m.isLatched)
    }

    @Test func tapThenLongHoldIsJustAHold() {
        var m = M()
        let actions = run([.down(0), .up(0.08), .down(0.20), .up(1.0)], into: &m)
        #expect(actions == [.begin, .end, .begin, .end])
        #expect(!m.isLatched)
    }

    @Test func longHoldThenTapIsNotADoubleTap() {
        var m = M()
        let actions = run([.down(0), .up(1.0), .down(1.1), .up(1.18)], into: &m)
        #expect(actions == [.begin, .end, .begin, .end])
        #expect(!m.isLatched)
    }

    @Test func cancelledTapDoesNotPairWithTheNext() {
        // Right ⌘ then C, then a quick tap: the shortcut was not a tap.
        var m = M()
        let actions = run([.down(0), .otherKey, .up(0.05), .down(0.15), .up(0.20)], into: &m)
        #expect(actions == [.begin, .cancel, .begin, .end])
        #expect(!m.isLatched)
    }

    // MARK: Timing edges

    @Test func tapJustUnderThresholdCounts() {
        var m = M()
        let actions = run([.down(0), .up(0.219), .down(0.30), .up(0.519)], into: &m)
        #expect(actions.last == .latch)
    }

    @Test func tapAtThresholdIsAHold() {
        var m = M()
        let actions = run([.down(0), .up(0.22), .down(0.30), .up(0.38)], into: &m)
        #expect(actions == [.begin, .end, .begin, .end])
    }

    @Test func secondTapJustInsideWindowLatches() {
        var m = M()
        let actions = run([.down(0), .up(0.05), .down(0.30), .up(0.399)], into: &m)
        #expect(actions.last == .latch)
    }

    @Test func secondTapAtWindowEdgeDoesNotLatch() {
        // Release to release, like the agent chord.
        var m = M()
        let actions = run([.down(0), .up(0.05), .down(0.30), .up(0.40)], into: &m)
        #expect(actions == [.begin, .end, .begin, .end])
        // But it is a fresh first tap, so one more quick tap pairs with it.
        #expect(run([.down(0.5), .up(0.55)], into: &m).last == .latch)
    }

    @Test func customThresholdsAreHonoured() {
        var m = M(tapThreshold: 0.5, doubleTapWindow: 1.0)
        let actions = run([.down(0), .up(0.4), .down(1.0), .up(1.3)], into: &m)
        #expect(actions.last == .latch)
    }

    // MARK: Safety

    @Test func latchTimesOutAndPastes() {
        var m = M(latchTimeout: 180)
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        #expect(m.handle(.tick(100)) == [])
        #expect(m.isLatched)
        #expect(m.handle(.tick(180.28)) == [.unlatch(.timeout), .end])
        #expect(m.phase == .idle)
    }

    @Test func timeoutCountsFromTheLatchNotFromTheLastTouch() {
        var m = M(latchTimeout: 10)
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        _ = m.handle(.down(9))                    // key down at the deadline
        #expect(m.handle(.tick(10.28)) == [.unlatch(.timeout), .end])
        #expect(m.handle(.up(10.5)) == [])
    }

    @Test func tickWhileHeldOrIdleDoesNothing() {
        var m = M(latchTimeout: 1)
        #expect(m.handle(.tick(50)) == [])
        _ = m.handle(.down(0))
        #expect(m.handle(.tick(50)) == [])
        #expect(m.latchDeadline == nil)
    }

    @Test func lockWhileLatchedDrops() {
        var m = M()
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        #expect(m.handle(.lock) == [.unlatch(.lock), .cancel])
    }

    @Test func lockWhileHeldDropsWithoutUnlatch() {
        var m = M()
        _ = m.handle(.down(0))
        #expect(m.handle(.lock) == [.cancel])
        #expect(m.handle(.up(1)) == [])
    }

    @Test func resetForgetsEverything() {
        var m = M()
        _ = run([.down(0), .up(0.08), .down(0.20), .up(0.28)], into: &m)
        m.reset()
        #expect(m.phase == .idle)
        // The next tap is a first tap: a lone quick tap after reset must not latch.
        #expect(run([.down(0.4), .up(0.45)], into: &m) == [.begin, .end])
    }
}

/// Deterministic, so a failing sequence can be replayed.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
