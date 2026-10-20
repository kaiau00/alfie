import Foundation
import Testing
@testable import MoeMeeting

// MARK: - Cues

struct CaptureCueScanTests {

    @Test func screenShareAndWalkthroughAndReferenceAreFound() {
        #expect(CaptureCueScan.cues(in: "OK, let me share my screen.") == [.screenShare])
        #expect(CaptureCueScan.cues(in: "I'll walk you through the flow") == [.walkthrough])
        #expect(CaptureCueScan.cues(in: "As you can see, revenue is up") == [.visualReference])
        #expect(CaptureCueScan.cues(in: "So we agreed on Tuesday then") == [.decision])
    }

    @Test func oneLineCanCarrySeveralCues() {
        let cues = CaptureCueScan.cues(in: "Let me share my screen and walk you through this slide")
        #expect(cues == [.screenShare, .walkthrough, .visualReference])
    }

    @Test func curlyApostrophesAndCaseAndSpacingAreFolded() {
        #expect(CaptureCueScan.cues(in: "I’LL   show you\nhow it works") == [.walkthrough])
        #expect(CaptureCueScan.cues(in: "Let’s go with option B") == [.decision])
    }

    @Test func plainSpeechIsNotACue() {
        #expect(CaptureCueScan.cues(in: "I looked at the numbers yesterday and they seem fine.").isEmpty)
        #expect(CaptureCueScan.cues(in: "Can you share the doc with me after?").isEmpty)
        #expect(CaptureCueScan.cues(in: "We should decide by Friday.").isEmpty)
    }

    @Test func phrasesMatchOnWordBoundariesNotSubstrings() {
        // The old substring match fired these; whole-word matching does not.
        #expect(CaptureCueScan.cues(in: "Well, the decision isn't final yet.").isEmpty)
        #expect(CaptureCueScan.cues(in: "I built this slideshow last night").isEmpty)
        // And still catches the real thing, punctuation and all.
        #expect(CaptureCueScan.cues(in: "So the decision is final.") == [.decision])
        #expect(CaptureCueScan.cues(in: "Look at this slide.") == [.visualReference])
    }

    @Test func endOfShareIsSeparate() {
        #expect(CaptureCueScan.endsShare("I'll stop sharing now"))
        #expect(!CaptureCueScan.endsShare("let me share my screen"))
        #expect(CaptureCueScan.cues(in: "I'll stop sharing now").isEmpty)
    }

    @Test func scanStartsAtTheCursorAndKeepsTheLine() {
        let segs = [
            Segment(start: 0, end: 2, speaker: .them(1), text: "let me share my screen"),
            Segment(start: 5, end: 7, speaker: .you, text: "sure"),
            Segment(start: 9, end: 12, speaker: .them(1), text: "this chart is the one"),
        ]
        let all = CaptureCueScan.scan(segs, from: 0)
        #expect(all.map(\.cue) == [.screenShare, .visualReference])
        #expect(all.map(\.segment.start) == [0, 9])
        #expect(CaptureCueScan.scan(segs, from: 1).map(\.cue) == [.visualReference])
        #expect(CaptureCueScan.scan(segs, from: 3).isEmpty)
        #expect(CaptureCueScan.scan(segs, from: 99).isEmpty)
    }
}

// MARK: - Scheduler

struct CaptureSchedulerTests {

    private func autoPolicy(recording: CaptureMode = .auto) -> CapturePolicy {
        var p = CapturePolicy()
        p.screenshots = .auto
        p.recording = recording
        p.minGapSeconds = 20
        p.maxAutoShots = 3
        p.clipMaxSeconds = 100
        p.clipIdleSeconds = 30
        return p
    }

    @Test func manualPolicyNeverDecidesAnything() {
        var s = CaptureScheduler()
        let p = CapturePolicy()      // manual / manual
        #expect(s.cue(.screenShare, at: 10, policy: p).isEmpty)
        #expect(s.cue(.actionItem, at: 40, policy: p).isEmpty)
        #expect(s.tick(at: 200, policy: p) == nil)
    }

    @Test func aVisualCueStartsAClipAndTakesAStill() {
        var s = CaptureScheduler()
        let d = s.cue(.screenShare, at: 10, policy: autoPolicy())
        #expect(d == [.startClip(reason: "screen-share"), .screenshot(reason: "screen-share")])
        #expect(s.isRecording)
        #expect(s.clip?.trigger == .auto)
    }

    @Test func aNonVisualCueTakesAStillOnly() {
        var s = CaptureScheduler()
        #expect(s.cue(.actionItem, at: 10, policy: autoPolicy()) == [.screenshot(reason: "action-item")])
        #expect(!s.isRecording)
    }

    @Test func cuesTheUserSwitchedOffAreIgnored() {
        var s = CaptureScheduler()
        var p = autoPolicy()
        p.cues = [.decision]
        #expect(s.cue(.screenShare, at: 10, policy: p).isEmpty)
        #expect(s.cue(.decision, at: 10, policy: p) == [.screenshot(reason: "decision")])
    }

    @Test func stillsKeepTheirDistanceAndTheirCeiling() {
        var s = CaptureScheduler()
        let p = autoPolicy(recording: .manual)
        #expect(s.cue(.decision, at: 0, policy: p) == [.screenshot(reason: "decision")])
        s.tookScreenshot(at: 0, trigger: .auto)
        #expect(s.cue(.decision, at: 10, policy: p).isEmpty)          // too soon
        #expect(s.cue(.decision, at: 20, policy: p) == [.screenshot(reason: "decision")])
        s.tookScreenshot(at: 20, trigger: .auto)
        #expect(s.cue(.decision, at: 50, policy: p) == [.screenshot(reason: "decision")])
        s.tookScreenshot(at: 50, trigger: .auto)
        #expect(s.autoShots == 3)
        #expect(s.cue(.decision, at: 500, policy: p).isEmpty)         // ceiling
    }

    @Test func theUsersOwnStillResetsTheGapButNotTheCeiling() {
        var s = CaptureScheduler()
        let p = autoPolicy(recording: .manual)
        s.tookScreenshot(at: 100, trigger: .user)
        #expect(s.autoShots == 0)
        #expect(s.cue(.decision, at: 105, policy: p).isEmpty)
        #expect(s.cue(.decision, at: 120, policy: p) == [.screenshot(reason: "decision")])
    }

    @Test func aRunningClipIsKeptAliveByVisualCuesAndEndsWhenTheyStop() {
        var s = CaptureScheduler()
        let p = autoPolicy()
        _ = s.cue(.screenShare, at: 0, policy: p)
        #expect(s.tick(at: 29, policy: p) == nil)
        _ = s.cue(.visualReference, at: 25, policy: p)     // refreshes
        #expect(s.clip?.lastCueAt == 25)
        #expect(s.tick(at: 54, policy: p) == nil)
        #expect(s.tick(at: 55, policy: p) == .stopClip)
    }

    @Test func aClipEndsAtItsMaximumLengthWhateverTheCues() {
        var s = CaptureScheduler()
        let p = autoPolicy()
        _ = s.cue(.screenShare, at: 0, policy: p)
        for t in stride(from: 10, through: 90, by: 10) { _ = s.cue(.visualReference, at: Double(t), policy: p) }
        #expect(s.tick(at: 99, policy: p) == nil)
        #expect(s.tick(at: 100, policy: p) == .stopClip)
    }

    @Test func stopSharingEndsAnAutomaticClipAndDamps() {
        var s = CaptureScheduler()
        let p = autoPolicy()
        _ = s.cue(.screenShare, at: 0, policy: p)
        #expect(s.shareEnded(at: 40) == .stopClip)
        s.stoppedClip()
        // "…and share this one instead" a moment later: no new clip, a still is fine.
        let d = s.cue(.screenShare, at: 42, policy: p)
        #expect(d == [.screenshot(reason: "screen-share")])
        #expect(!s.isRecording)
        // Later, a new share is a new clip.
        s.tookScreenshot(at: 42, trigger: .auto)
        #expect(s.cue(.screenShare, at: 80, policy: p).contains(.startClip(reason: "screen-share")))
    }

    @Test func theUsersOwnClipIsNeverEndedByTheRules() {
        var s = CaptureScheduler()
        let p = autoPolicy()
        s.startedClip(at: 0, reason: "demo", trigger: .user)
        #expect(s.tick(at: 1000, policy: p) == nil)
        #expect(s.shareEnded(at: 1000) == nil)
        // and a cue does not start a second one
        #expect(!s.cue(.screenShare, at: 5, policy: p).contains(.startClip(reason: "screen-share")))
        s.stoppedClip()
        #expect(!s.isRecording)
    }

    @Test func recordingOffMeansNoClipsEvenOnAShare() {
        var s = CaptureScheduler()
        var p = autoPolicy()
        p.recording = .off
        #expect(s.cue(.screenShare, at: 0, policy: p) == [.screenshot(reason: "screen-share")])
    }
}

// MARK: - Policy and record on disk

struct CapturePolicyCodingTests {

    @Test func defaultsAreManualAndFillInMissingKeys() throws {
        let p = try JSONDecoder().decode(CapturePolicy.self, from: Data("{}".utf8))
        #expect(p == CapturePolicy())
        #expect(p.screenshots == .manual && p.recording == .manual && p.scope == .display)
        #expect(!p.isAutomatic && p.isEnabled)
    }

    @Test func aBadKeyDoesNotSinkTheRest() throws {
        let json = #"{"screenshots":"auto","scope":"nonsense","minGapSeconds":-4,"cues":["decision"],"clipMaxSeconds":1}"#
        let p = try JSONDecoder().decode(CapturePolicy.self, from: Data(json.utf8))
        #expect(p.screenshots == .auto)
        #expect(p.scope == .display)
        #expect(p.minGapSeconds == 0)
        #expect(p.cues == [.decision])
        #expect(p.clipMaxSeconds == 5)
    }

    @Test func roundTrips() throws {
        var p = CapturePolicy()
        p.recording = .auto
        p.scope = .region
        p.region = CaptureRegion(x: 10, y: 20, width: 300, height: 200)
        p.cues = [.nameMention]
        let back = try JSONDecoder().decode(CapturePolicy.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test func recordsLoadWithoutCaptures() throws {
        let json = #"{"startedAt":"2026-08-30T14:15:00Z","durationSeconds":60,"folder":"/x"}"#
        let r = try MeetingRecord.decoder().decode(MeetingRecord.self, from: Data(json.utf8))
        #expect(r.captures.isEmpty)
        #expect(r.callApp == nil)
    }

    @Test func recordsKeepTheirCaptures() throws {
        var r = MeetingRecord(startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 100, folder: "/x")
        r.captures = [CaptureRecord(file: "shots/001-00m05s-decision.jpg", kind: .screenshot, at: 5,
                                    trigger: .auto, reason: "decision", caption: "A slide titled Q3")]
        r.callApp = "Zoom"
        let back = try MeetingRecord.load2(r.json())
        #expect(back.captures == r.captures)
        #expect(back.callApp == "Zoom")
    }

    @Test func aCaptureMissingItsKindIsAScreenshot() throws {
        let json = #"{"file":"shots/001-00m05s.jpg"}"#
        let c = try JSONDecoder().decode(CaptureRecord.self, from: Data(json.utf8))
        #expect(c.kind == .screenshot && c.at == 0 && c.trigger == .user && c.reason == "")
    }
}

private extension MeetingRecord {
    static func load2(_ data: Data) throws -> MeetingRecord { try decoder().decode(MeetingRecord.self, from: data) }
}

// MARK: - Files and lines

struct CaptureFileTests {

    @Test func namesSortAndSayWhen() {
        #expect(CaptureFile.name(index: 3, at: 32.7, kind: .screenshot, reason: "screen-share")
                == "shots/003-00m32s-screen-share.jpg")
        #expect(CaptureFile.name(index: 12, at: 754, kind: .recording, reason: "")
                == "clips/012-12m34s.mp4")
    }

    @Test func slugsAreTame() {
        #expect(CaptureFile.slug("The Q3 dashboard!! (top-left)") == "the-q3-dashboard-top")
        #expect(CaptureFile.slug("../../etc/passwd") == "etc-passwd")
        #expect(CaptureFile.slug("a very long reason that goes on and on and on") .count <= 24)
        #expect(CaptureFile.slug("émoji 🎉 ok") == "moji-ok")
        #expect(CaptureFile.slug("") == "")
    }

    @Test func onlyFilesInsideTheTwoFoldersAreSafe() {
        #expect(CaptureFile.isSafe("shots/001-00m05s-decision.jpg"))
        #expect(CaptureFile.isSafe("clips/002-01m00s.mp4"))
        #expect(!CaptureFile.isSafe("shots/../meeting.json"))
        #expect(!CaptureFile.isSafe("/etc/passwd"))
        #expect(!CaptureFile.isSafe("system.wav"))
        #expect(!CaptureFile.isSafe("shots/"))
        #expect(!CaptureFile.isSafe("shots/.hidden"))
    }

    @Test func theLineReadsLikeABookmark() {
        let still = CaptureRecord(file: "shots/001-00m05s-decision.jpg", kind: .screenshot, at: 5,
                                  trigger: .auto, reason: "decision", caption: "A slide titled Q3 plan")
        #expect(still.line == "[00:05] screenshot · decision — A slide titled Q3 plan (shots/001-00m05s-decision.jpg)")
        let clip = CaptureRecord(file: "clips/001-01m00s-demo.mp4", kind: .recording, at: 60,
                                 trigger: .user, reason: "demo", durationSeconds: 95)
        #expect(clip.line == "[01:00] clip 01:35 · demo (clips/001-01m00s-demo.mp4)")
    }

    @Test func summaryMarkdownListsTheScreens() {
        let notes = MeetingNotes(title: "T", summary: "S", decisions: [], actionItems: [], todos: [], openQuestions: [])
        let md = notes.markdown(date: Date(timeIntervalSince1970: 0), duration: 10,
                                captures: [CaptureRecord(file: "shots/001-00m05s.jpg", kind: .screenshot, at: 5,
                                                         trigger: .user, reason: "")])
        #expect(md.contains("## Screens\n\n- [00:05] screenshot (shots/001-00m05s.jpg)"))
        #expect(!notes.markdown(date: Date(), duration: 10).contains("## Screens"))
    }

    @Test func thePromptCarriesOnlyCaptionedCaptures() {
        let seen = CaptureRecord(file: "shots/001-00m05s.jpg", kind: .screenshot, at: 5, trigger: .user,
                                 reason: "", caption: "The pricing table")
        let blind = CaptureRecord(file: "shots/002-00m09s.jpg", kind: .screenshot, at: 9, trigger: .user, reason: "")
        let prompt = MeetingSummaryPrompt.user(transcript: "x", date: Date(), duration: 10, captures: [seen, blind])
        #expect(prompt.contains("[00:05] The pricing table"))
        #expect(!prompt.contains("00:09"))
        #expect(!MeetingSummaryPrompt.user(transcript: "x", date: Date(), duration: 10, captures: [blind])
                    .contains("Screenshots were taken"))
    }

    @Test func regionsAreClampedAndTinyOnesRefused() {
        let bounds = CaptureRegion(x: 0, y: 0, width: 1000, height: 800)
        #expect(CaptureRegion(x: 900, y: 700, width: 300, height: 300).clamped(to: bounds)
                == CaptureRegion(x: 900, y: 700, width: 100, height: 100))
        #expect(CaptureRegion(x: 2000, y: 0, width: 100, height: 100).clamped(to: bounds) == nil)
        #expect(CaptureRegion(x: 0, y: 0, width: 10, height: 10).clamped(to: bounds) == nil)
        #expect(!CaptureRegion(x: 0, y: 0, width: 39, height: 400).isUsable)
    }
}

// MARK: - Captions

struct CaptureCaptionTests {

    @Test func cleanTakesTheFirstLineAndStripsQuotes() {
        #expect(CaptureCaption.clean("\"A dashboard titled Revenue, Q3 up 12%.\"\n\nMore.") == "A dashboard titled Revenue, Q3 up 12%.")
        #expect(CaptureCaption.clean("- A Zoom grid of four people") == "A Zoom grid of four people")
        #expect(CaptureCaption.clean("  \n  ") == nil)
        #expect(CaptureCaption.clean("I can't see any image.") == nil)
        #expect(CaptureCaption.clean(String(repeating: "x", count: 300)) == nil)
    }

    @Test func userPromptCarriesTheReasonAndTheContext() {
        let u = CaptureCaption.user(reason: "screen-share", recentLines: "[00:10] them (speaker 1): here is the plan")
        #expect(u.contains("screen-share") && u.contains("here is the plan"))
        #expect(CaptureCaption.user(reason: "", recentLines: "").contains("the user asked"))
    }
}

// MARK: - Detecting a call

struct MeetingDetectorTests {

    /// The timing tests pin the thresholds they were written against, so
    /// tuning the shipped defaults (for a faster offer) does not rewrite the
    /// arithmetic in every case. These are the pre-tuning values.
    private func detector(hold: Double = 6, browser: Double = 20,
                          browserEvent: Double = 8, end: Double = 25) -> MeetingDetector {
        var d = MeetingDetector()
        d.holdSeconds = hold
        d.browserHoldSeconds = browser
        d.browserHoldWithEventSeconds = browserEvent
        d.endAfterSeconds = end
        return d
    }

    private func zoom(_ input: Bool, out: Bool = true) -> CallSignal {
        CallSignal(bundleID: "us.zoom.xos", input: input, output: out)
    }
    private func chromeHelper(_ input: Bool, out: Bool) -> CallSignal {
        CallSignal(bundleID: "com.google.Chrome.helper", input: input, output: out)
    }

    @Test func aNativeAppHoldingTheMicIsACallAfterTheHold() {
        var d = detector()
        #expect(d.observe([zoom(true)], at: 0) == nil)
        #expect(d.observe([zoom(true)], at: 3) == nil)
        let v = d.observe([zoom(true)], at: 6)
        #expect(v?.kind == .started)
        #expect(v?.app.name == "Zoom")
        #expect(d.current?.name == "Zoom")
        // and only once
        #expect(d.observe([zoom(true)], at: 7) == nil)
    }

    @Test func aBlipDoesNotCount() {
        var d = detector()
        #expect(d.observe([zoom(true)], at: 0) == nil)
        #expect(d.observe([], at: 3) == nil)
        #expect(d.observe([zoom(true)], at: 6) == nil)     // the clock restarted
        #expect(d.observe([zoom(true)], at: 12)?.kind == .started)
    }

    @Test func theCallEndsAfterTheMicHasBeenReleasedForAWhile() {
        var d = detector()
        _ = d.observe([zoom(true)], at: 0)
        _ = d.observe([zoom(true)], at: 6)
        #expect(d.observe([zoom(false)], at: 10) == nil)
        #expect(d.observe([zoom(true)], at: 20) == nil)     // came back: a mute toggle
        #expect(d.observe([], at: 30) == nil)
        #expect(d.observe([], at: 50) == nil)
        let v = d.observe([], at: 55)
        #expect(v?.kind == .ended)
        #expect(d.current == nil)
    }

    @Test func aBrowserHoldingTheMicAloneIsACallAfterTheLongWait() {
        // The bug: a solo Meet has no audio out, so the old rule (mic AND
        // output) never fired. Mic alone must still become a call — slowly.
        var d = detector()
        #expect(d.observe([chromeHelper(true, out: false)], at: 0) == nil)
        #expect(d.observe([chromeHelper(true, out: false)], at: 19) == nil)
        #expect(d.observe([chromeHelper(true, out: false)], at: 20)?.app.name == "Chrome")
    }

    @Test func aBrowserIsAVideoCallFastWhenCorroborated() {
        // Camera on → 8 s, whatever the audio is doing (the solo-Meet fix).
        var cam = detector()
        #expect(cam.observe([chromeHelper(true, out: false)], cameraOn: true, at: 0) == nil)
        #expect(cam.observe([chromeHelper(true, out: false)], cameraOn: true, at: 7) == nil)
        #expect(cam.observe([chromeHelper(true, out: false)], cameraOn: true, at: 8)?.app.name == "Chrome")
        // Audio out → 8 s.
        var snd = detector()
        #expect(snd.observe([chromeHelper(true, out: true)], at: 0) == nil)
        #expect(snd.observe([chromeHelper(true, out: true)], at: 8)?.kind == .started)
        // Calendar event → 8 s.
        var cal = detector()
        #expect(cal.observe([chromeHelper(true, out: false)], calendarNow: true, at: 0) == nil)
        #expect(cal.observe([chromeHelper(true, out: false)], calendarNow: true, at: 8)?.kind == .started)
    }

    @Test func cameraWithoutTheMicIsNotACall() {
        // The camera is a corroborator, never a trigger on its own: no known
        // app holds the mic, so nothing is a candidate.
        var d = detector()
        #expect(d.observe([], cameraOn: true, at: 0) == nil)
        #expect(d.observe([], cameraOn: true, at: 60) == nil)
    }

    @Test func helpersFoldIntoTheirApp() {
        // Chrome's mic is in one helper and its sound in another.
        let signals = [CallSignal(bundleID: "com.google.Chrome.helper", input: true, output: false),
                       CallSignal(bundleID: "com.google.Chrome.helper.plugin", input: false, output: true)]
        let apps = MeetingDetector.appsWithMic(signals, ignored: [])
        #expect(apps.count == 1)
        #expect(apps[0].app.name == "Chrome" && apps[0].output)
    }

    @Test func aNativeAppBeatsABrowser() {
        var d = detector()
        let both = [chromeHelper(true, out: true), zoom(true)]
        _ = d.observe(both, at: 0)
        #expect(d.observe(both, at: 6)?.app.name == "Zoom")
    }

    @Test func ignoredAppsAndUnknownAppsAreInvisible() {
        var d = detector()
        let slack = CallSignal(bundleID: "com.tinyspeck.slackmacgap", input: true, output: true)
        #expect(d.observe([slack], ignored: ["com.tinyspeck.slackmacgap"], at: 0) == nil)
        #expect(d.observe([slack], ignored: ["com.tinyspeck.slackmacgap"], at: 30) == nil)
        let unknown = CallSignal(bundleID: "com.example.voicememo", input: true, output: true)
        #expect(d.observe([unknown], at: 0) == nil)
        #expect(d.observe([unknown], at: 30) == nil)
    }

    @Test func acknowledgedCallsStillFireTheEndVerdict() {
        // The bug: acknowledge() set dismissed=true, so the "seems to have
        // ended" / auto-stop verdict never fired for a recorded meeting.
        var d = detector()
        _ = d.observe([zoom(true)], at: 0)
        #expect(d.observe([zoom(true)], at: 6)?.kind == .started)
        d.acknowledge()      // meeting is now recording this call
        _ = d.observe([], at: 10)
        let v = d.observe([], at: 40)
        #expect(v?.kind == .ended)
    }

    @Test func aSleepGapDoesNotSatisfyAHoldOrAnEnd() {
        // A browser held the mic 2 s, then the Mac slept and woke 1000 s
        // later: the gap must not count as 998 s of holding.
        var d = detector()
        #expect(d.observe([chromeHelper(true, out: true)], at: 0) == nil)
        #expect(d.observe([chromeHelper(true, out: true)], at: 2) == nil)
        #expect(d.observe([chromeHelper(true, out: true)], at: 1000) == nil)   // clock reset
        #expect(d.observe([chromeHelper(true, out: true)], at: 1008)?.kind == .started)
        // And a pending end is not granted for free across a sleep.
        var e = detector()
        _ = e.observe([zoom(true)], at: 0)
        _ = e.observe([zoom(true)], at: 6)
        _ = e.observe([], at: 10)          // quietSince = 10
        #expect(e.observe([], at: 2000) == nil)   // the gap does not end it
        #expect(e.observe([], at: 2026)?.kind == .ended)
    }

    @Test func dismissedCallsEndQuietly() {
        var d = detector()
        _ = d.observe([zoom(true)], at: 0)
        #expect(d.observe([zoom(true)], at: 6)?.kind == .started)
        d.dismiss()
        _ = d.observe([], at: 10)
        #expect(d.observe([], at: 40) == nil)      // no "ended"
        #expect(d.current == nil)
        // the next call is noticed afresh
        _ = d.observe([zoom(true)], at: 50)
        #expect(d.observe([zoom(true)], at: 56)?.kind == .started)
    }

    @Test func matchingIsExactOrByHelperPrefix() {
        #expect(CallApps.match(bundleID: "us.zoom.xos")?.name == "Zoom")
        #expect(CallApps.match(bundleID: "com.apple.WebKit.GPU")?.name == "Safari")
        #expect(CallApps.match(bundleID: "com.google.Chromecast") == nil)
        #expect(CallApps.match(bundleID: "") == nil)
    }

    @Test func theOfferSpeaksTheAppsOwnWord() {
        let slack = CallApps.match(bundleID: "com.tinyspeck.slackmacgap")!
        #expect(MeetingOfferText.title(slack) == "Slack huddle detected")
        #expect(MeetingOfferText.body(slack, mode: .ask, countdown: nil).hasPrefix("Record it?"))
        #expect(MeetingOfferText.body(slack, mode: .auto, countdown: 5).contains("5 s"))
        #expect(MeetingOfferText.never(slack) == "Never for Slack")
        #expect(MeetingOfferText.ended(slack).contains("Slack huddle"))
    }
}
