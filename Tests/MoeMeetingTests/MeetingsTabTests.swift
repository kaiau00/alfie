import Foundation
import Testing
@testable import MoeMeeting

// The Meetings tab reads a directory of folders written by earlier versions
// of Moe, by a Moe that was killed mid-meeting, and — because they are
// ordinary files in the user's home — by anything else at all. None of those
// may lose a meeting, point a button at the wrong folder, or leave the tab
// saying "None yet." over a directory full of recordings.
//
// Everything here runs against a real temporary directory, because the bugs
// being pinned are about what is on disk, not about what a record says.

private struct MeetingsDir {
    let url: URL

    init() {
        // Never ~/.moe: a scratch directory of this test's own.
        // Resolved, because /var is a symlink to /private/var on a Mac and
        // `contentsOfDirectory` hands back the resolved side: the point of
        // these tests is that two paths for one folder compare equal.
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("moe-meetings-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func folder(_ name: String) -> URL {
        let f = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    @discardableResult
    func write(_ name: String, _ text: String, in folder: URL) -> URL {
        let u = folder.appendingPathComponent(name)
        try? text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func record(_ record: MeetingRecord, in folder: URL) {
        try? record.json().write(to: folder.appendingPathComponent("meeting.json"))
    }
}

private func aRecord(folder: String, at: Date = Date(timeIntervalSince1970: 1_788_099_300),
                     notes: MeetingNotes? = nil) -> MeetingRecord {
    MeetingRecord(startedAt: at, durationSeconds: 600, folder: folder,
                  notes: notes, summarised: notes != nil)
}

struct MeetingFolderScanTests {

    @Test func anEmptyDirectoryIsNoMeetingsRatherThanAFailure() {
        let dir = MeetingsDir(); defer { dir.remove() }
        #expect(MeetingListing.load(directory: dir.url).isEmpty)
    }

    @Test func aDirectoryThatDoesNotExistIsNoMeetingsRatherThanACrash() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-not-here-\(UUID().uuidString)", isDirectory: true)
        #expect(MeetingListing.load(directory: missing).isEmpty)
    }

    @Test func aGoodRecordLoadsAndKeepsItsNotes() {
        let dir = MeetingsDir(); defer { dir.remove() }
        let f = dir.folder("2026-08-30-1415")
        dir.record(aRecord(folder: f.path, notes: MeetingNotes(title: "Pricing", summary: "We shipped.")), in: f)
        let out = MeetingListing.load(directory: dir.url)
        #expect(out.count == 1)
        #expect(MeetingListing.title(out[0]) == "Pricing")
        #expect(out[0].folder == f.path)
    }

    /// The bug: Moe killed mid-meeting never writes `meeting.json`, so the
    /// folder held the WAVs and the live transcript and the tab showed
    /// nothing at all — "None yet." over a real meeting.
    @Test func aFolderWithNoRecordAtAllIsStillListedAndSaysWhy() {
        let dir = MeetingsDir(); defer { dir.remove() }
        let f = dir.folder("2026-08-30-1415")
        dir.write("transcript.txt", "[00:01] them (speaker 1): hello\n", in: f)
        let out = MeetingListing.load(directory: dir.url)
        #expect(out.count == 1)
        #expect(out[0].folder == f.path)
        #expect(MeetingListing.blurb(out[0]).contains("could not read"))
        // Dated from the folder name, so it sorts and reads like a meeting.
        #expect(out[0].startedAt == MeetingFolder.date(from: "2026-08-30-1415"))
    }

    @Test func aTruncatedOrCorruptRecordIsStillListed() {
        let dir = MeetingsDir(); defer { dir.remove() }
        let truncated = dir.folder("2026-08-30-1000")
        dir.write("meeting.json", "{\"startedAt\":\"2026-08-30T10:0", in: truncated)
        let junk = dir.folder("2026-08-30-1100")
        dir.write("meeting.json", "this is not json at all", in: junk)
        let empty = dir.folder("2026-08-30-1200")
        dir.write("meeting.json", "", in: empty)

        let out = MeetingListing.load(directory: dir.url)
        #expect(out.count == 3)
        #expect(out.allSatisfy { MeetingListing.blurb($0).contains("could not read") })
        #expect(Set(out.map(\.folder)) == Set([truncated.path, junk.path, empty.path]))
    }

    /// A record naming a folder that is not the one it was found in used to
    /// be believed: the tab read that other meeting's transcript and aimed
    /// Delete at it. The directory on disk is the only path there is.
    @Test func theFolderIsWhereTheRecordWasFoundNotWhatItClaims() {
        let dir = MeetingsDir(); defer { dir.remove() }
        let a = dir.folder("2026-08-30-1415")
        let b = dir.folder("2026-08-30-1500")
        dir.record(aRecord(folder: b.path), in: a)
        dir.record(aRecord(folder: b.path, at: Date(timeIntervalSince1970: 1_788_102_000)), in: b)

        let out = MeetingListing.load(directory: dir.url)
        #expect(out.count == 2)
        #expect(Set(out.map(\.folder)) == Set([a.path, b.path]))
    }

    /// Two records claiming one folder gave the list two rows with the same
    /// identity, which is a SwiftUI `ForEach` keyed on a duplicate.
    @Test func everyListedMeetingHasItsOwnIdentity() {
        let dir = MeetingsDir(); defer { dir.remove() }
        for name in ["2026-08-30-1415", "2026-08-30-1500", "2026-08-30-1600"] {
            let f = dir.folder(name)
            dir.record(aRecord(folder: "/same/for/all"), in: f)
        }
        let folders = MeetingListing.load(directory: dir.url).map(\.folder)
        #expect(folders.count == 3)
        #expect(Set(folders).count == 3)
    }

    /// Same title, different meetings: the list must show both.
    @Test func twoMeetingsWithTheSameTitleAreTwoRows() {
        let dir = MeetingsDir(); defer { dir.remove() }
        let notes = MeetingNotes(title: "Standup", summary: "The usual.")
        let a = dir.folder("2026-08-30-0900")
        let b = dir.folder("2026-08-31-0900")
        dir.record(aRecord(folder: a.path, at: Date(timeIntervalSince1970: 1_788_000_000), notes: notes), in: a)
        dir.record(aRecord(folder: b.path, at: Date(timeIntervalSince1970: 1_788_090_000), notes: notes), in: b)

        let out = MeetingListing.load(directory: dir.url)
        #expect(out.count == 2)
        #expect(out.map { MeetingListing.title($0) } == ["Standup", "Standup"])
        #expect(Set(out.map(\.folder)).count == 2)
        // Newest first.
        #expect(out[0].folder == b.path)
    }

    @Test func strayFilesAndFoldersThatAreNotMeetingsAreIgnored() {
        let dir = MeetingsDir(); defer { dir.remove() }
        try? "junk".write(to: dir.url.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        dir.folder("some-other-directory")
        let real = dir.folder("2026-08-30-1415")
        dir.record(aRecord(folder: real.path), in: real)
        #expect(MeetingListing.load(directory: dir.url).map(\.folder) == [real.path])
    }

    @Test func anIncompleteMeetingListsAsStoppedEarly() {
        let dir = MeetingsDir(); defer { dir.remove() }
        let f = dir.folder("2026-08-30-1415")
        var r = aRecord(folder: f.path)
        r.incomplete = true
        r.summaryFailure = "Moe quit while the meeting was being recorded"
        dir.record(r, in: f)
        let out = MeetingListing.load(directory: dir.url)
        #expect(out.count == 1)
        #expect(out[0].incomplete)
        #expect(MeetingListing.blurb(out[0]) == "Stopped early — transcript only.")
    }

    @Test func aMeetingWithNoSummarySaysSoRatherThanShowingNothing() {
        let dir = MeetingsDir(); defer { dir.remove() }
        let f = dir.folder("2026-08-30-1415")
        var r = aRecord(folder: f.path)
        r.summaryFailure = "brain unavailable"
        dir.record(r, in: f)
        #expect(MeetingListing.blurb(MeetingListing.load(directory: dir.url)[0]) == "No notes — brain unavailable.")
        // And with no failure recorded either, still a sentence.
        #expect(!MeetingListing.blurb(aRecord(folder: f.path)).isEmpty)
    }
}

struct OlderRecordSchemaTests {

    /// The first records Moe wrote: three fields and nothing else.
    @Test func theOriginalThreeFieldsAreEnough() throws {
        let json = """
        {"startedAt":"2026-08-30T14:15:00Z","durationSeconds":1320,"folder":"/x/2026-08-30-1415"}
        """
        let r = try MeetingRecord.decoder().decode(MeetingRecord.self, from: Data(json.utf8))
        #expect(r.transcriptFile == "transcript.txt")
        #expect(r.taker == "moe-agent")
        #expect(!r.incomplete)
        #expect(r.bookmarks.isEmpty)
        #expect(!MeetingListing.title(r).isEmpty)
    }

    /// One key of the wrong shape used to throw, and the whole meeting fell
    /// out of the tab. The meeting is real; only its notes are unreadable.
    @Test func aKeyOfTheWrongShapeCostsThatKeyAndNotTheMeeting() throws {
        let json = """
        {"startedAt":"2026-08-30T14:15:00Z","durationSeconds":1320,"folder":"/x/m",
         "notes":"this used to be an object","bookmarks":42,"speakers":"one two",
         "offTheRecord":{"nope":true},"incomplete":"yes"}
        """
        let r = try MeetingRecord.decoder().decode(MeetingRecord.self, from: Data(json.utf8))
        #expect(r.notes == nil)
        #expect(r.bookmarks.isEmpty)
        #expect(r.speakers.isEmpty)
        #expect(r.offTheRecord.isEmpty)
        #expect(!r.incomplete)
        #expect(r.durationSeconds == 1320)
    }

    @Test func aRecordWithNoDateIsStillRefused() {
        let json = "{\"durationSeconds\":10,\"folder\":\"/x/m\"}"
        #expect((try? MeetingRecord.decoder().decode(MeetingRecord.self, from: Data(json.utf8))) == nil)
    }

    @Test func aRecordRoundTripsThroughJSON() throws {
        var r = aRecord(folder: "/x/m", notes: MeetingNotes(title: "T", summary: "S"))
        r.incomplete = true
        r.bookmarks = [Bookmark(time: 12)]
        let back = try MeetingRecord.decoder().decode(MeetingRecord.self, from: r.json())
        #expect(back == r)
    }

    @Test func theFolderNameRoundTripsToTheMinute() {
        let d = Date(timeIntervalSince1970: 1_788_099_300)
        let name = MeetingFolder.name(for: d)
        let back = MeetingFolder.date(from: name)
        #expect(back != nil)
        #expect(abs((back ?? .distantPast).timeIntervalSince(d)) < 60)
        // The suffix a same-minute collision adds does not confuse it.
        #expect(MeetingFolder.date(from: name + "-2") == back)
        #expect(MeetingFolder.date(from: "not-a-meeting-folder") == nil)
        #expect(MeetingFolder.date(from: "") == nil)
    }
}

struct TranscriptFileTests {

    private func tmp(_ text: String) -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-transcript-\(UUID().uuidString).txt")
        try? text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    @Test func aMissingFileReadsAsEmptyRatherThanThrowing() {
        let gone = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-gone-\(UUID().uuidString).txt")
        #expect(TranscriptFile.read(gone) == "")
    }

    @Test func aShortTranscriptComesBackWhole() {
        let u = tmp("[00:01] you: hello\n[00:03] them (speaker 1): hi\n")
        defer { try? FileManager.default.removeItem(at: u) }
        let out = TranscriptFile.read(u)
        #expect(out.hasPrefix("[00:01] you: hello"))
        #expect(!out.contains("long transcript"))
    }

    /// The bug: the detail view put the whole file into one `Text`. A
    /// day-long meeting is megabytes, laid out on the main thread.
    @Test func aVeryLongTranscriptIsCappedAndSaysWhere() {
        let line = "[00:01] them (speaker 1): the same sentence over and over again\n"
        let u = tmp(String(repeating: line, count: 40_000))   // ~2.5 MB
        defer { try? FileManager.default.removeItem(at: u) }
        let out = TranscriptFile.read(u)
        #expect(out.utf8.count <= TranscriptFile.maxBytes + TranscriptFile.truncationNote.utf8.count)
        #expect(out.hasSuffix(TranscriptFile.truncationNote))
        #expect(out.hasPrefix("[00:01]"))
    }

    /// A cut at a byte offset can land inside a multi-byte scalar; the view
    /// must still get text rather than "".
    @Test func aCutInsideAMultiByteCharacterStillDecodes() {
        let u = tmp(String(repeating: "é", count: 400))       // 800 bytes
        defer { try? FileManager.default.removeItem(at: u) }
        for cap in 99...103 {
            let out = TranscriptFile.read(u, maxBytes: cap)
            #expect(out.hasPrefix("é"))
            #expect(out.hasSuffix(TranscriptFile.truncationNote))
        }
    }

    @Test func anEmptyFileReadsAsEmpty() {
        let u = tmp("")
        defer { try? FileManager.default.removeItem(at: u) }
        #expect(TranscriptFile.read(u) == "")
    }

    /// `transcriptFile` comes out of a file on disk. It names a file in the
    /// meeting's own folder or it names nothing.
    @Test func theTranscriptNameIsAPlainFileName() {
        #expect(TranscriptFile.safeName("transcript.txt") == "transcript.txt")
        #expect(TranscriptFile.safeName("live.txt") == "live.txt")
        #expect(TranscriptFile.safeName("../../../etc/passwd") == "passwd")
        #expect(TranscriptFile.safeName("/etc/passwd") == "passwd")
        #expect(TranscriptFile.safeName("..") == "transcript.txt")
        #expect(TranscriptFile.safeName("") == "transcript.txt")
        #expect(TranscriptFile.safeName("/") == "transcript.txt")
    }
}

/// `Timeline.clock` renders a number that came out of `meeting.json`, so it
/// has to survive whatever is in there. `Int(someDouble)` is a trap on a
/// NaN, an infinity, or anything past `Int.max`, and a record saying
/// `"durationSeconds": 1e19` crashed the app as the Meetings tab drew it.
struct ClockFromARecordTests {

    @Test(arguments: [Double.nan, .infinity, -.infinity, 1e19, -1e19, 1e300,
                      -1, -0.5, 0, Double(Int.max), Double(Int.min)])
    func anyNumberAtAllRendersAsAClock(_ t: Double) {
        let out = Timeline.clock(t)
        #expect(out.count >= 5)
        #expect(out.contains(":"))
    }

    @Test func theOrdinaryValuesAreUnchanged() {
        #expect(Timeline.clock(0) == "00:00")
        #expect(Timeline.clock(9.9) == "00:09")
        #expect(Timeline.clock(75 * 60 + 12) == "75:12")
    }

    @Test func aDurationTooLargeForAClockIsPinnedRatherThanTrapping() {
        #expect(Timeline.clock(.infinity) == Timeline.clock(Timeline.maxClockSeconds))
        #expect(Timeline.clock(1e19) == Timeline.clock(Timeline.maxClockSeconds))
    }

    /// The whole path: a hand-edited record through the loader and into the
    /// two strings the list draws for it.
    @Test func aRecordWithAnImpossibleDurationStillDrawsARow() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("moe-clock-\(UUID().uuidString)", isDirectory: true)
        let folder = dir.appendingPathComponent("2026-08-30-1415", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"startedAt":"2026-08-30T14:15:00Z","durationSeconds":1e19,"folder":"\(folder.path)"}
        """
        try? json.write(to: folder.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)

        let out = MeetingListing.load(directory: dir)
        #expect(out.count == 1)
        #expect(!Timeline.clock(out[0].durationSeconds).isEmpty)
        #expect(!MeetingListing.title(out[0]).isEmpty)
        #expect(!MeetingListing.blurb(out[0]).isEmpty)
    }
}
