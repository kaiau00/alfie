import Foundation
import MoeMeeting

/// `Moe --meeting-test`: the transcribe → diarize → format → summarise
/// pipeline over files, for scripts/test-meeting.sh. Uses the same
/// `SpeechModels` the app uses, so what passes here is what a meeting runs.
enum MeetingPipelineTest {
    static func run(source: URL, out: URL) async -> Int32 {
        @Sendable func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        let system = source.appendingPathComponent("system.wav")
        let mic = source.appendingPathComponent("mic.wav")
        guard FileManager.default.fileExists(atPath: system.path), FileManager.default.fileExists(atPath: mic.path) else {
            err("meeting-test: need system.wav and mic.wav in \(source.path)"); return 2
        }
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { err("meeting-test: \(error)"); return 2 }
        try? FileManager.default.removeItem(at: out.appendingPathComponent("transcript.txt"))

        let config = Config.load()
        let router = SpeechRouter.forUser()
        let t0 = Date()
        do { try await router.parakeet.warmUp(progress: { err("  \($0)") }) } catch {
            err("meeting-test: speech model failed to load: \(error)"); return 3
        }
        err(String(format: "meeting-test: speech model ready in %.1f s", Date().timeIntervalSince(t0)))
        let asr = SpeechModels(router: router, locale: config.locale)
        let diarizer = FluidDiarizer()
        let transcriber = MeetingTranscriber(folder: out, asr: asr, diarizer: diarizer)

        // Frame counts from the files, as the recorder would report them.
        func frames(_ url: URL) -> Int {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return max(0, (size - Wav.headerBytes) / 2)
        }
        let available: (MeetingRecorder.Stream) -> Int = { $0 == .system ? frames(system) : frames(mic) }
        let urls: (MeetingRecorder.Stream) -> URL = { $0 == .system ? system : mic }
        let duration = Double(max(frames(system), frames(mic))) / meetingSampleRate

        let t1 = Date()
        // Live windows first (any full 30 s ones), then the remainder + diarization.
        while await transcriber.tick(available: available, url: urls) {}
        let segments = await transcriber.finish(available: available, url: urls)
        err(String(format: "meeting-test: transcribed + diarized %.1f s of audio in %.2f s; %d lines, speakers %@",
                   duration, Date().timeIntervalSince(t1), segments.count,
                   Timeline.speakerNumbers(segments).map(String.init).joined(separator: ",")))
        for w in transcriber.warnings { err("meeting-test: warning: \(w)") }

        let drift = DriftReport(systemFrames: frames(system), micFrames: frames(mic), wallSeconds: duration)
        // `MOE_MEETING_BOOKMARKS=3.5,7` (debug builds) plays "note this" at
        // those seconds, so the script can check the labels and the prompt.
        let bookmarks = (TestHooks.env("MOE_MEETING_BOOKMARKS") ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map { Bookmark(time: $0) }
        for b in bookmarks { Log.write("meeting: bookmark at \(Timeline.clock(b.time))") }
        // Two brains, on two sessions, exactly as a real meeting has them.
        // One brain for both was the bug: the scan's "reply with
        // {actions:…}" is what the notes request then got answered with.
        // If this file shared one, the script would pass over the failure
        // it exists to catch.
        let meetingID = UUID().uuidString.lowercased()
        let scanBrain: MeetingBrain? = config.meetingSummarise
            ? HermesMeetingBrain(config: config, purpose: .scan, meetingID: meetingID) : nil
        let brain: MeetingBrain? = config.meetingSummarise
            ? HermesMeetingBrain(config: config, purpose: .notes, meetingID: meetingID) : nil

        // The minute scan, run once over the whole transcript here — live it
        // fires every ActionItemScan.interval with whatever is new since the
        // last one (Conductor.scanForActionItems). Same prompt, same cursor,
        // same merge, so what the script checks is what a meeting does; the
        // fake gateway tells the scan from the summary by <new-lines>.
        var liveActions: [MeetingNotes.ActionItem] = []
        if let brain = scanBrain {
            var cursor = LiveCursor()
            let fresh = cursor.take(segments)
            if !fresh.isEmpty,
               let reply = try? await brain.complete(system: ActionItemScan.system,
                                                     user: ActionItemScan.user(newLines: Timeline.format(fresh))) {
                liveActions = ActionItemScan.merge(liveActions, ActionItemScan.parse(reply))
                err("meeting-test: minute scan found \(liveActions.count) action item(s)")
            }
        }

        // `MOE_MEETING_CAPTURES=1` (debug builds) stands in for two captures
        // taken during the meeting — a captioned screenshot and a clip — the
        // way `Conductor` hands them to `MeetingSession.finish`.
        var captures: [CaptureRecord] = []
        if TestHooks.env("MOE_MEETING_CAPTURES") == "1" {
            captures = [
                CaptureRecord(file: "shots/001-00m03s-screen-share.jpg", kind: .screenshot, at: 3.2, trigger: .auto,
                              reason: "screen-share", caption: "A slide titled Ship plan with Tuesday circled"),
                CaptureRecord(file: "clips/001-00m05s.mp4", kind: .recording, at: 5, trigger: .user, reason: "",
                              durationSeconds: 2.5),
            ]
            for c in captures {
                _ = try? MeetingScreenshot.write(Data("stand-in".utf8), to: out, relative: c.file)
            }
        }

        let outcome = await MeetingSummary.write(
            folder: out, segments: segments, startedAt: Date(), duration: duration, drift: drift,
            warnings: transcriber.warnings, bookmarks: bookmarks, liveActions: liveActions,
            captures: captures, callApp: captures.isEmpty ? nil : "Zoom", brain: brain,
            summarise: config.meetingSummarise, deleteRecordings: false)
        err("meeting-test: \(outcome.message)")
        if let n = transcriber.diarizedSpeakers { err("meeting-test: diarizer found \(n) speaker(s)") }
        Log.write("meeting: \(outcome.message) (\(segments.count) lines, speakers \(outcome.record.speakers))")
        if let f = outcome.record.summaryFailure { err("meeting-test: no notes: \(f)") }
        print(Timeline.format(segments))
        return 0
    }
}
