import Foundation
import Testing
@testable import MoeMeeting

struct MeetingNotesTests {

    let canned = """
    {"title": "Ship date for meeting mode", "summary": "Agreed to ship on Tuesday.",
     "decisions": ["Ship the meeting feature on Tuesday"],
     "action_items": [{"who": "them (speaker 2)", "what": "send the notes", "when": "after the call"}],
     "open_questions": ["Who tests the release?"]}
    """

    @Test func parsesABareObject() throws {
        let n = try #require(MeetingNotes.parse(canned))
        #expect(n.title == "Ship date for meeting mode")
        #expect(n.decisions == ["Ship the meeting feature on Tuesday"])
        #expect(n.actionItems == [.init(who: "them (speaker 2)", what: "send the notes", when: "after the call")])
        #expect(n.openQuestions == ["Who tests the release?"])
    }

    @Test func parsesAFencedObjectAndProseAroundIt() throws {
        let fenced = "Here are the notes:\n```json\n\(canned)\n```\nLet me know if you want changes."
        let n = try #require(MeetingNotes.parse(fenced))
        #expect(n.title == "Ship date for meeting mode")
    }

    @Test func toleratesMissingArraysAndStringActionItems() throws {
        let n = try #require(MeetingNotes.parse(#"{"title": "Quick sync", "action_items": ["call Dan", ""], "decisions": null}"#))
        #expect(n.title == "Quick sync")
        #expect(n.summary == "")
        #expect(n.decisions == [])
        #expect(n.actionItems == [.init(who: "", what: "call Dan", when: "")])
    }

    @Test func rejectsRepliesThatAreNotNotes() {
        #expect(MeetingNotes.parse("I can't summarise that.") == nil)
        #expect(MeetingNotes.parse("{}") == nil)
        #expect(MeetingNotes.parse(#"{"decisions": ["x"]}"#) == nil)
        #expect(MeetingNotes.parse("") == nil)
    }

    @Test func markdownHasTheSectionsThatHaveContent() throws {
        let n = try #require(MeetingNotes.parse(canned))
        let md = n.markdown(date: Date(timeIntervalSince1970: 0), duration: 8.3, footer: ["", "Clock drift: none"])
        #expect(md.hasPrefix("# Ship date for meeting mode\n"))
        #expect(md.contains("00:08_"))
        #expect(md.contains("## Decisions\n\n- Ship the meeting feature on Tuesday"))
        #expect(md.contains("- **them (speaker 2)**: send the notes — by after the call"))
        #expect(md.contains("## Open questions\n\n- Who tests the release?"))
        #expect(md.contains("_Clock drift: none_"))
        let bare = MeetingNotes(title: "T", summary: "S").markdown(date: Date(), duration: 0)
        #expect(!bare.contains("## Decisions"))
        #expect(!bare.contains("---"))
    }

    /// The bucket that was missing: "we're going to need monitoring if
    /// we're managing a hundred of these" is nobody's action item and no
    /// decision, and used to survive only in the transcript.
    @Test func parsesAndRendersWorkNobodyTookOn() throws {
        let n = try #require(MeetingNotes.parse("""
        {"title": "Rollout", "summary": "Where it landed.",
         "todos": ["Monitoring and visibility for managing agents at scale",
                   "Fix auto-compact so sessions stop running out of context"]}
        """))
        #expect(n.todos.count == 2)
        let md = n.markdown(date: Date(timeIntervalSince1970: 0), duration: 60)
        #expect(md.contains("## To do\n\n- Monitoring and visibility for managing agents at scale"))
        #expect(!MeetingNotes(title: "T", summary: "S").markdown(date: Date(), duration: 0).contains("## To do"))
    }

    /// A `meeting.json` written before `todos` existed still loads, rather
    /// than losing its whole notes object over one absent key.
    @Test func recordsWrittenBeforeTodosStillDecode() throws {
        let old = Data(#"{"title":"T","summary":"S","decisions":[],"action_items":[],"open_questions":[]}"#.utf8)
        let n = try JSONDecoder().decode(MeetingNotes.self, from: old)
        #expect(n.title == "T")
        #expect(n.todos == [])
    }

    @Test func actionItemLineWithoutOwnerOrDate() {
        #expect(MeetingNotes.ActionItem(who: "", what: "book the room", when: "").line == "- **Someone**: book the room")
    }

    @Test func recordRoundTripsThroughJSON() throws {
        var r = MeetingRecord(startedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 61.5,
                              folder: "/tmp/m", speakers: [1, 2], driftNote: "none")
        r.notes = MeetingNotes.parse(canned)
        r.summaryFile = "summary.md"
        r.summarised = true
        let data = try r.json()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"action_items\""))
        #expect(text.contains("\"startedAt\" : \"2023-11-14T22:13:20Z\""))
        let back = try MeetingRecord.decoder().decode(MeetingRecord.self, from: data)
        #expect(back.incomplete == false)
        // A record written before `incomplete`/`taker`/`bookmarks` existed still loads.
        let old = Data("""
        {"startedAt":"2023-11-14T22:13:20Z","durationSeconds":61.5,"folder":"/x","transcriptFile":"transcript.txt",
         "speakers":[1],"driftNote":"","summarised":false,"recordingsDeleted":false}
        """.utf8)
        let legacy = try MeetingRecord.decoder().decode(MeetingRecord.self, from: old)
        #expect(legacy.taker == "moe-agent" && legacy.bookmarks.isEmpty && !legacy.incomplete)
        #expect(back == r)
    }

    @Test func folderNameIsDateAndMinute() {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 30; c.hour = 14; c.minute = 5
        let d = Calendar.current.date(from: c)!
        #expect(MeetingFolder.name(for: d) == "2026-08-30-1405")
    }

    @Test func promptCarriesTheTranscriptFencedAndTheSessionKeyIsFixed() {
        let u = MeetingSummaryPrompt.user(transcript: "[00:00] you: hi", date: Date(), duration: 90)
        #expect(u.contains("<transcript>\n[00:00] you: hi\n</transcript>"))
        #expect(u.contains("01:30 long"))
        #expect(MeetingSummaryPrompt.sessionKey == "moe-meeting")
        #expect(MeetingSummaryPrompt.system.contains("\"action_items\""))
        #expect(MeetingSummaryPrompt.system.contains("Do not call any tool"))
    }
}

struct MeetingIntentTests {

    @Test func exactStartPhrases() {
        #expect(MeetingIntent.match("start a meeting") == .start)
        #expect(MeetingIntent.match("Start recording the meeting.") == .start)
        #expect(MeetingIntent.match("Hey Alfie, start a meeting") == .start)
        #expect(MeetingIntent.match("moe please start the meeting now") == .start)
    }

    @Test func exactStopPhrases() {
        #expect(MeetingIntent.match("stop the meeting") == .stop)
        #expect(MeetingIntent.match("Stop recording, please") == .stop)
        #expect(MeetingIntent.match("end meeting") == .stop)
    }

    @Test func anythingElseGoesToTheBrain() {
        #expect(MeetingIntent.match("start a meeting with Dan tomorrow") == nil)
        #expect(MeetingIntent.match("when is the meeting") == nil)
        #expect(MeetingIntent.match("start") == nil)
        #expect(MeetingIntent.match("don't start a meeting") == nil)
        #expect(MeetingIntent.match("") == nil)
    }

    /// Ordinary sentences that merely contain a phrase never start a
    /// recording: the match is the whole utterance, not a substring.
    @Test func ordinarySentencesNeverMatch() {
        for s in ["we should start a meeting about the roadmap",
                  "I think we should start a meeting",
                  "start a meeting and then email Dan",
                  "remind me to start the meeting at three",
                  "did you start the meeting",
                  "start a meeting, actually no",
                  "hey alfie, what time does the meeting start",
                  "let's not stop the meeting yet",
                  "stop recording my screen",
                  "the meeting can start",
                  "start a meeting in Zoom"] {
            #expect(MeetingIntent.match(s) == nil, "\(s)")
        }
    }

    /// The bug this grammar exists for: the same request in the words a
    /// person actually uses. Every one of these was refused by the phrase
    /// list, with an instruction to say "start a meeting" instead.
    @Test func paraphrasesStart() {
        for s in ["begin taking notes",
                  "start taking notes",
                  "take notes",
                  "take minutes",
                  "begin the meeting",
                  "start transcribing",
                  "record this call",
                  "capture this meeting",
                  "kick off the meeting",
                  "could you please start taking notes now",
                  "hey alfie, take notes for this meeting",
                  "I want to record this session"] {
            #expect(MeetingIntent.match(s) == .start, "\(s)")
        }
    }

    @Test func paraphrasesStop() {
        for s in ["stop taking notes",
                  "finish the meeting",
                  "wrap up the meeting",
                  "end the recording",
                  "quit recording",
                  "stop the notes"] {
            #expect(MeetingIntent.match(s) == .stop, "\(s)")
        }
    }

    /// "turn off recording" must never read as a start. It is not in the
    /// vocabulary at all, which is the safe way to fail: it goes to the
    /// brain, which asks for the stop by marker.
    @Test func turningItOffIsNeverAStart() {
        #expect(MeetingIntent.match("turn off recording") != .start)
        #expect(MeetingIntent.match("turn off the recording") != .start)
    }
}

/// The way in for a phrasing the grammar does not cover: the model's own
/// marker, which Moe acts on — after its own consent sheet.
struct MeetingMarkerTests {

    @Test func markersAreRead() {
        #expect(MeetingIntent.marker(in: "Recording now. <meeting:start/>") == .start)
        #expect(MeetingIntent.marker(in: "<meeting:stop/> Writing your notes.") == .stop)
        #expect(MeetingIntent.marker(in: "Sure, I'll take notes.") == nil)
    }

    /// The marker is Moe's instruction, never a word to show or say.
    @Test func markersAreStripped() {
        #expect(MeetingIntent.strippingMarkers("Recording. <meeting:start/>")
                    .trimmingCharacters(in: .whitespaces) == "Recording.")
        #expect(MeetingIntent.strippingMarkers("<meeting:stop/>Done.") == "Done.")
        #expect(MeetingIntent.strippingMarkers("nothing here") == "nothing here")
    }

    /// A reply that carries both is a confused reply; the request that
    /// matters is the one that starts a recording somebody asked for.
    @Test func startWinsOverStop() {
        #expect(MeetingIntent.marker(in: "<meeting:stop/> <meeting:start/>") == .start)
    }
}

/// The summary writer against a stub brain — the file outputs, both when
/// the brain answers and when it cannot.
struct MeetingSummaryTests {

    struct Brain: MeetingBrain {
        let reply: String?
        func complete(system: String, user: String) async throws -> String {
            guard let reply else { throw URLError(.cannotConnectToHost) }
            return reply
        }
    }

    let segments = [Segment(start: 0, end: 5, speaker: .them(1), text: "ship on Tuesday"),
                    Segment(start: 6, end: 8, speaker: .you, text: "sounds good")]

    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moe-meeting-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesSummaryAndRecordWhenTheBrainAnswers() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reply = #"{"title": "Ship date", "summary": "Tuesday it is.", "decisions": ["Ship Tuesday"], "action_items": [], "open_questions": []}"#
        let out = await MeetingSummary.write(folder: dir, segments: segments, startedAt: Date(), duration: 8,
                                             drift: DriftReport(systemSeconds: 8, micSeconds: 8, wallSeconds: 8),
                                             brain: Brain(reply: reply), summarise: true)
        #expect(out.record.summarised)
        #expect(out.message == "Notes written.")
        let md = try String(contentsOf: try #require(out.summaryURL), encoding: .utf8)
        #expect(md.hasPrefix("# Ship date"))
        #expect(md.contains("- Ship Tuesday"))
        let record = try MeetingRecord.load(out.recordURL)
        #expect(record.notes?.title == "Ship date")
        #expect(record.speakers == [1])
        #expect(record.summaryFile == "summary.md")
    }

    @Test func brainUnavailableWritesTheRecordAndSaysSo() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await MeetingSummary.write(folder: dir, segments: segments, startedAt: Date(), duration: 8,
                                             drift: DriftReport(systemSeconds: 8, micSeconds: 8, wallSeconds: 8),
                                             brain: Brain(reply: nil), summarise: true)
        #expect(!out.record.summarised)
        #expect(out.summaryURL == nil)
        #expect(out.message.contains("not reachable"))
        #expect(out.record.summaryFailure?.hasPrefix("brain unavailable") == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
        #expect(FileManager.default.fileExists(atPath: out.recordURL.path))
    }

    @Test func summarisingOffNeverAsksTheBrain() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = await MeetingSummary.write(folder: dir, segments: segments, startedAt: Date(), duration: 8,
                                             drift: DriftReport(systemSeconds: 8, micSeconds: 8, wallSeconds: 8),
                                             brain: Brain(reply: "{\"title\": \"should not be used\"}"), summarise: false)
        #expect(!out.record.summarised)
        #expect(out.record.summaryFailure?.contains("off") == true)
    }

    @Test func deleteRecordingsOnlyAfterASummary() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["system.wav", "mic.wav"] { try Data([0]).write(to: dir.appendingPathComponent(name)) }
        let failed = await MeetingSummary.write(folder: dir, segments: segments, startedAt: Date(), duration: 8,
                                                drift: DriftReport(systemSeconds: 8, micSeconds: 8, wallSeconds: 8),
                                                brain: Brain(reply: nil), summarise: true, deleteRecordings: true)
        #expect(!failed.record.recordingsDeleted)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.wav").path))
        let ok = await MeetingSummary.write(folder: dir, segments: segments, startedAt: Date(), duration: 8,
                                            drift: DriftReport(systemSeconds: 8, micSeconds: 8, wallSeconds: 8),
                                            brain: Brain(reply: #"{"title": "t", "summary": "s"}"#), summarise: true,
                                            deleteRecordings: true)
        #expect(ok.record.recordingsDeleted)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.wav").path))
    }
}

/// The transcriber against a stub recogniser and a synthetic pair of WAVs:
/// windows, offsets, the incremental file, the final relabel.
struct MeetingTranscriberTests {

    /// Returns a token per second of audio it is given, so the timeline
    /// shows exactly which window each call covered.
    struct Asr: MeetingAsr {
        func transcribeTimed(_ samples: [Float]) async throws -> [TimedToken] {
            let seconds = Int(Double(samples.count) / meetingSampleRate)
            // The two streams must not produce the same words: identical
            // text at the same moment is what echo suppression exists to
            // remove, so a fixture that spoke in unison would test nothing.
            // The mic is written quieter, and that is what tells them apart.
            let peak = samples.map(abs).max() ?? 0
            let voice = peak < 0.15 ? "m" : "s"
            return (0..<max(seconds, 1)).map {
                TimedToken("▁\(voice)\($0)", Double($0), Double($0) + 0.5)
            }
        }
    }

    struct Diarizer: MeetingDiarizer {
        func diarize(_ samples: [Float]) async throws -> [SpeakerSpan] {
            [SpeakerSpan("B", 0, 45), SpeakerSpan("A", 45, 200)]
        }
    }

    /// A WAV of `seconds` of tone written the way the sink writes, given a
    /// syllable-rate envelope.
    ///
    /// It used to be a flat tone, and a flat tone no longer reaches the
    /// recogniser however loud it is: the gate before recognition asks
    /// whether a window varies against its own noise floor, because that —
    /// and not the level — is what separates speech from a fan
    /// (`Windowing.hasSpeech`). Stand-in audio for a talking meeting has to
    /// look like talking.
    func wav(_ url: URL, seconds: Double, amplitude: Double = 0.2) throws {
        let n = Int(seconds * meetingSampleRate)
        let samples = (0..<n).map { i -> Float in
            let t = Double(i) / meetingSampleRate
            let syllable = pow((1 - cos(2 * .pi * 3 * t)) / 2, 2)
            return Float(sin(Double(i) * 0.05) * amplitude * syllable)
        }
        var data = Wav.header(dataBytes: UInt32(n * 2))
        samples.withUnsafeBufferPointer { p in
            Wav.pcm16(p).withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    @Test func windowsAreConsumedInOrderAndAppendedToTheFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("system.wav"), mic = dir.appendingPathComponent("mic.wav")
        try wav(system, seconds: 70)
        try wav(mic, seconds: 20, amplitude: 0.1)
        let t = MeetingTranscriber(folder: dir, asr: Asr(), diarizer: Diarizer(), windowSeconds: 30)
        let frames: (MeetingRecorder.Stream) -> Int = { $0 == .system ? 70 * 16_000 : 20 * 16_000 }
        let url: (MeetingRecorder.Stream) -> URL = { $0 == .system ? system : mic }

        // Only the system stream has a full window; the mic (20 s) waits.
        #expect(await t.tick(available: frames, url: url))
        let first = t.timeline
        #expect(first.allSatisfy { $0.speaker == .them(nil) })
        #expect(first.first?.start == 0)
        let consumedAfterOne = t.pending(available: frames)[.system]!
        #expect(consumedAfterOne > 40 * 16_000 && consumedAfterOne <= 43 * 16_000)   // cut inside the last 3 s

        // Second window starts where the first was cut, not at 30 s.
        #expect(await t.tick(available: frames, url: url))
        let second = t.timeline
        #expect(second.count > first.count)
        #expect(second.last!.start >= 27)
        let onDisk = try String(contentsOf: t.transcriptURL, encoding: .utf8)
        #expect(onDisk.split(separator: "\n").count == second.count)

        // Finish: the rest of both streams, then the relabel from diarization.
        let final = await t.finish(available: frames, url: url)
        #expect(final.contains { $0.speaker == .you })
        #expect(final.contains { $0.speaker == .them(1) })
        #expect(final.contains { $0.speaker == .them(2) })
        #expect(final.first { !$0.speaker.isYou }!.speaker == .them(1))   // B spoke first → speaker 1
        #expect(t.pending(available: frames) == [.system: 0, .mic: 0])
        let rewritten = try String(contentsOf: t.transcriptURL, encoding: .utf8)
        #expect(rewritten == Timeline.format(final) + "\n")
        #expect(t.warnings.isEmpty)
    }

    /// The recogniser "hears" words across the whole window; only the line
    /// over the loud second survives, and the mic's first 1.5 s (echo
    /// canceller warming up) count as silence however loud they are.
    @Test func linesOverQuietAudioAndTheMicWarmUpAreDropped() async throws {
        struct Chatty: MeetingAsr {
            func transcribeTimed(_ samples: [Float]) async throws -> [TimedToken] {
                [TimedToken("▁early", 0.4, 0.9), TimedToken("▁loud", 5.0, 5.8), TimedToken("▁quiet", 8.0, 8.6)]
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 16_000
        var samples = [Float](repeating: 0, count: 10 * rate)
        for i in (Int(0.3 * Double(rate)))..<(Int(1.2 * Double(rate))) { samples[i] = Float(sin(Double(i) * 0.3)) * 0.1 }  // AEC leak
        for i in (5 * rate)..<(6 * rate) { samples[i] = Float(sin(Double(i) * 0.3)) * 0.1 }                                // real speech
        for i in (8 * rate)..<(9 * rate) { samples[i] = Float(sin(Double(i) * 0.3)) * 0.004 }                              // -48 dBFS
        var data = Wav.header(dataBytes: UInt32(samples.count * 2))
        samples.withUnsafeBufferPointer { p in Wav.pcm16(p).withUnsafeBytes { data.append(contentsOf: $0) } }
        let mic = dir.appendingPathComponent("mic.wav"), system = dir.appendingPathComponent("system.wav")
        try data.write(to: mic)
        try data.write(to: system)
        let t = MeetingTranscriber(folder: dir, asr: Chatty(), diarizer: nil)
        let final = await t.finish(available: { _ in samples.count }, url: { $0 == .mic ? mic : system })
        #expect(final.filter(\.speaker.isYou).map(\.text) == ["loud"])
        // The system stream has no warm-up: its early line stands.
        #expect(final.filter { !$0.speaker.isYou }.map(\.text) == ["early", "loud"])
    }

    /// The end-of-meeting rebuild of "them" (per diarized speaker) is made
    /// from the tokens — and must not resurrect a line that was dropped as
    /// hallucinated when the window was first recognised.
    @Test func droppedLinesStayDroppedAfterDiarization() async throws {
        struct Chatty: MeetingAsr {
            func transcribeTimed(_ samples: [Float]) async throws -> [TimedToken] {
                [TimedToken("▁loud", 5.0, 5.8), TimedToken("▁quiet", 8.0, 8.6)]
            }
        }
        struct OneSpeaker: MeetingDiarizer {
            func diarize(_ samples: [Float]) async throws -> [SpeakerSpan] { [SpeakerSpan("A", 0, 10)] }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 16_000
        var samples = [Float](repeating: 0, count: 10 * rate)
        for i in (5 * rate)..<(6 * rate) { samples[i] = Float(sin(Double(i) * 0.3)) * 0.1 }
        for i in (8 * rate)..<(9 * rate) { samples[i] = Float(sin(Double(i) * 0.3)) * 0.004 }
        var data = Wav.header(dataBytes: UInt32(samples.count * 2))
        samples.withUnsafeBufferPointer { p in Wav.pcm16(p).withUnsafeBytes { data.append(contentsOf: $0) } }
        let mic = dir.appendingPathComponent("mic.wav"), system = dir.appendingPathComponent("system.wav")
        try data.write(to: system)
        try Data(Wav.header(dataBytes: 0)).write(to: mic)
        let t = MeetingTranscriber(folder: dir, asr: Chatty(), diarizer: OneSpeaker())
        let final = await t.finish(available: { $0 == .system ? samples.count : 0 }, url: { $0 == .mic ? mic : system })
        #expect(final.map(\.text) == ["loud"])
        #expect(final.first?.speaker == .them(1))
    }

    @Test func silenceIsSkippedWithoutCallingTheRecogniser() async throws {
        struct Loud: MeetingAsr {
            func transcribeTimed(_ samples: [Float]) async throws -> [TimedToken] { throw URLError(.unknown) }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let quiet = dir.appendingPathComponent("system.wav")
        var data = Wav.header(dataBytes: UInt32(16_000 * 2 * 5))
        data.append(Data(count: 16_000 * 2 * 5))
        try data.write(to: quiet)
        let t = MeetingTranscriber(folder: dir, asr: Loud(), diarizer: nil)
        let final = await t.finish(available: { _ in 5 * 16_000 }, url: { _ in quiet })
        #expect(final.isEmpty)
        #expect(t.warnings.isEmpty)
    }

    @Test func wavFrameReadsAreByOffsetAndShortAtEOF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moe-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try wav(url, seconds: 1)
        let all = try Wav.readFrames(url, from: 0, count: 16_000)
        #expect(all.count == 16_000)
        let tail = try Wav.readFrames(url, from: 15_990, count: 100)
        #expect(tail.count == 10)
        #expect(tail == Array(all[15_990...]))
        #expect(try Wav.readFrames(url, from: 0, count: 0).isEmpty)
        let whole = try Wav.read(url)
        #expect(whole.count == 16_000)
        #expect(abs(whole[100] - all[100]) < 1e-4)
    }
}
