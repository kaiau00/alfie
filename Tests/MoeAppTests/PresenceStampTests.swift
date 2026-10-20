import Foundation
import Testing
@testable import Moe

/// `~/.moe/presence.json` says why the person is not "active": the fork's
/// `at_this_mac` (browser hand-over) keeps a person who asked from the Mac
/// moments ago "at the Mac" for their turn — but only when the stamp says,
/// in so many words, the screen is not locked, the Mac not asleep and the
/// display not asleep. A stamp without those fields reads as "not here".
struct PresenceStampTests {
    @Test func idleButThereSaysNotLockedNotAsleep() {
        let b = Conductor.presenceBody(locked: false, asleep: false, idle: 400, now: 1000)
        #expect(b["active"] as? Bool == false)
        #expect(b["locked"] as? Bool == false)
        #expect(b["asleep"] as? Bool == false)
        #expect(b["idle"] as? Int == 400)
        #expect(b["at"] as? Double == 1000)
    }

    @Test func lockedOrAsleepIsSaid() {
        #expect(Conductor.presenceBody(locked: true, asleep: false, idle: 1, now: 0)["locked"] as? Bool == true)
        #expect(Conductor.presenceBody(locked: false, asleep: true, idle: 1, now: 0)["asleep"] as? Bool == true)
        #expect(Conductor.presenceBody(locked: true, asleep: false, idle: 1, now: 0)["active"] as? Bool == false)
    }

    @Test func aDarkDisplayIsAwayAndSaysSo() {
        let b = Conductor.presenceBody(locked: false, asleep: false, displayAsleep: true, idle: 1, now: 0)
        #expect(b["display_asleep"] as? Bool == true)
        #expect(b["active"] as? Bool == false)
        #expect(Conductor.presenceBody(locked: false, asleep: false, idle: 1, now: 0)["display_asleep"] as? Bool == false)
    }

    @Test func activeIsUnchangedForItsOldReaders() {
        #expect(Conductor.presenceBody(locked: false, asleep: false, idle: 5, now: 0)["active"] as? Bool == true)
        #expect(Conductor.presenceBody(locked: false, asleep: false,
                                       idle: Conductor.presenceIdleSeconds, now: 0)["active"] as? Bool == false)
    }
}
