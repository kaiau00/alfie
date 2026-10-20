import AVFoundation
import Foundation
import Testing
@testable import MoeMeeting

// Which channel of a voice-processing bus is the microphone, and how the
// answer is measured rather than assumed. Helpers live in
// `ResamplerChannelTests.swift`; nothing here opens a device.

// MARK: - Measuring which channel is the microphone


struct ChannelLevelsTests {

    @Test func nothingIsReportedUntilABufferArrives() throws {
        let levels = ChannelLevels(channels: 7)
        #expect(levels.dbfs() == nil)
        let format = try #require(testBus(7))
        levels.add(testTone(on: 6, of: format))
        let db = try #require(levels.dbfs())
        #expect(db.count == 7)
    }

    @Test func theChannelCarryingTheToneIsTheLoudOne() throws {
        let format = try #require(testBus(7))
        let levels = ChannelLevels(channels: 7)
        levels.add(testTone(on: 3, of: format))
        let db = try #require(levels.dbfs())
        #expect(abs(db[3] - (-9)) < 1.5)
        for ch in [0, 1, 2, 4, 5, 6] { #expect(db[ch] < -100) }
    }
}

struct ChannelReportTests {

    /// A meeting where nobody spoke: every channel near the floor together.
    /// This must not warn about anything — it is the commonest case there
    /// is, and the measured 37 s quiet room looked exactly like it.
    @Test func aQuietRoomIsNotAWrongChannel() {
        let report = ChannelReport.make(db: [-65, -66, -64], chosen: 0)
        #expect(report.warning == nil)
        #expect(report.implausiblyQuiet == false)
    }

    /// Positive evidence, which is the only thing that warns: the channel
    /// being recorded is dead and another one is carrying audio.
    @Test func aReferenceChannelBeingRecordedIsCalledOut() {
        let report = ChannelReport.make(db: [-92, -95, -30, -95], chosen: 0)
        let warning = report.warning ?? ""
        #expect(warning.contains("channel 2"))
        #expect(warning.contains("62 dB louder"))
        #expect(report.implausiblyQuiet)
    }

    /// Loud audio elsewhere is not on its own a wrong channel: a person
    /// talking 8 dB above their own room is still that person.
    @Test func aSmallDifferenceIsNotAVerdict() {
        #expect(ChannelReport.make(db: [-40, -32], chosen: 0).warning == nil)
        #expect(ChannelReport.make(db: [-40, -25], chosen: 0).warning != nil)
    }

    /// Another channel that is itself near the floor proves nothing, however
    /// much louder it is in relative terms.
    @Test func aLouderButStillSilentChannelIsNotEvidence() {
        #expect(ChannelReport.make(db: [-200, -60], chosen: 0).warning == nil)
        #expect(ChannelReport.make(db: [-200, -20], chosen: 0).warning != nil)
    }

    /// -80 dBFS is the line: fifteen decibels below the measured quiet room,
    /// ten above a dithered dead channel.
    @Test func onlyAnImpossibleLevelReadsAsADeadDevice() {
        #expect(ChannelReport.make(db: [-70], chosen: 0).implausiblyQuiet == false)
        #expect(ChannelReport.make(db: [-90], chosen: 0).implausiblyQuiet)
        #expect(ChannelReport.make(db: [-200], chosen: 0).implausiblyQuiet)
    }

    /// A mono or stereo bus is reduced whole; there is no choice to
    /// second-guess and nothing to warn about.
    @Test func aBusWithNoChoiceMakesNoVerdict() {
        let report = ChannelReport.make(db: [-200, -200], chosen: nil)
        #expect(report.warning == nil)
        #expect(report.implausiblyQuiet == false)
        #expect(report.line == "channels ch0 -∞, ch1 -∞")
    }

    @Test func theLineNamesEveryChannelAndTheOneBeingRecorded() {
        let report = ChannelReport.make(db: [-62.4, -200, -30], chosen: 0)
        #expect(report.line == "channels ch0 -62 dBFS, ch1 -∞, ch2 -30 dBFS → recording ch0")
    }
}

struct MicChannelWatchTests {

    @Test func theTableIsLoggedOnceTheCancellerHasSettled() {
        var watch = MicChannelWatch()
        let report = ChannelReport.make(db: [-62, -200], chosen: 0)
        #expect(watch.observe(report, at: 1).isEmpty)
        #expect(watch.observe(report, at: 3) == ["channels ch0 -62 dBFS, ch1 -∞ → recording ch0"])
        // Once, not every tick.
        #expect(watch.observe(report, at: 4).isEmpty)
    }

    @Test func nothingIsLoggedBeforeTheFirstBuffer() {
        var watch = MicChannelWatch()
        #expect(watch.observe(nil, at: 30).isEmpty)
    }

    @Test func theVerdictWaitsTwentySecondsAndThenSaysNothingIfAllIsWell() {
        var watch = MicChannelWatch()
        let report = ChannelReport.make(db: [-52, -200], chosen: 0)
        _ = watch.observe(report, at: 3)
        #expect(watch.observe(report, at: 19).isEmpty)
        #expect(watch.observe(report, at: 20).isEmpty)
    }

    @Test func aDeadChannelBesideALiveOneIsWarnedAboutOnce() {
        var watch = MicChannelWatch()
        let report = ChannelReport.make(db: [-95, -30], chosen: 0)
        _ = watch.observe(report, at: 3)
        let lines = watch.observe(report, at: 20)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("WARNING"))
        #expect(lines[0].contains("channel 1"))
        #expect(watch.observe(report, at: 40).isEmpty)
    }

    /// The other half: nothing else is loud either, but the level is below
    /// anything a microphone produces. That is a device delivering nothing,
    /// and it must not be reported as a quiet room.
    @Test func aDeadDeviceWithNoLiveNeighbourIsStillWarnedAbout() {
        var watch = MicChannelWatch()
        let report = ChannelReport.make(db: [-200, -200], chosen: 0)
        _ = watch.observe(report, at: 3)
        let lines = watch.observe(report, at: 20)
        #expect(lines.count == 1)
        #expect(lines[0].contains("not a quiet room"))
    }

    /// And the case this must never fire on.
    @Test func thirtySevenSecondsOfARealQuietRoomProducesNoWarning() {
        var watch = MicChannelWatch()
        // The measured levels of ~/.moe/meetings/2026-08-30-1611/mic.wav.
        let report = ChannelReport.make(db: [-65.3, -200, -200], chosen: 0)
        _ = watch.observe(report, at: 3)
        #expect(watch.observe(report, at: 37).isEmpty)
    }
}
