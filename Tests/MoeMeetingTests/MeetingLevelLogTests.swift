import Foundation
import Testing
@testable import MoeMeeting

// MARK: - Levels, in the log

struct LevelLogTests {

    @Test func nothingAtAllIsMinusInfinityNotAQuietRoom() {
        #expect(LevelLog.dbfs(-200) == "-∞")
        #expect(LevelLog.dbfs(-.infinity) == "-∞")
        #expect(LevelLog.dbfs(.nan) == "-∞")
        #expect(LevelLog.dbfs(-52.4) == "-52 dBFS")
        #expect(LevelLog.dbfs(-0.2) == "0 dBFS")
    }

    @Test func aLineEveryIntervalCarryingTheLoudestReadingInIt() {
        var log = LevelLog(interval: 15)
        #expect(log.observe(micDb: -60, systemDb: -200, at: 0) == nil)
        #expect(log.observe(micDb: -52, systemDb: -200, at: 7) == nil)
        #expect(log.observe(micDb: -70, systemDb: -200, at: 14.9) == nil)
        let line = log.observe(micDb: -70, systemDb: -200, at: 15)
        #expect(line == "levels mic -52 dBFS, system -∞ at 00:15 (loudest in 15 s)")
        // The window resets: the next line is about the next fifteen seconds.
        #expect(log.observe(micDb: -40, systemDb: -30, at: 20) == nil)
        #expect(log.observe(micDb: -80, systemDb: -80, at: 30)
                == "levels mic -40 dBFS, system -30 dBFS at 00:30 (loudest in 15 s)")
    }

    @Test func aChannelThatNeverSoundedReadsAsNoSignal() {
        var log = LevelLog(interval: 1)
        _ = log.observe(micDb: -200, systemDb: -200, at: 0)
        #expect(log.observe(micDb: -200, systemDb: -200, at: 1)?.contains("mic -∞, system -∞") == true)
    }
}
