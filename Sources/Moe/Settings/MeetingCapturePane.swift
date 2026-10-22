import AppKit
import MoeDesign
import MoeMeeting
import SwiftUI

/// Settings › Meeting Capture: whether Moe notices calls, and what pictures
/// it keeps of the screen while you are on one.
///
/// Two things are said plainly that the pane before it left to be worked
/// out. A "screenshot" is a still picture and a "screen recording" is a
/// short clip — of the same thing, the shared screen — and each has the
/// same three answers: Off, When I ask, Automatically. The cue list, the
/// caption switch and the numbers behind "automatically" are one sheet
/// off the Screenshots row, because most people will never change them
/// and every one of them made the page harder to read.
struct MeetingCapturePane: View {
    @ObservedObject var conductor: Conductor
    @State private var showCues = false

    private var policy: CapturePolicy { conductor.config.meetingCapture }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Meeting Capture")
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    noticing
                    pictures
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
            }
        }
        .background(Theme.raised)
        .sheet(isPresented: $showCues) {
            CaptureCuesSheet(conductor: conductor) { showCues = false }
        }
    }

    // MARK: - Noticing calls

    private var noticing: some View {
        let ignored = conductor.config.meetingDetectIgnored
        return SettingGroup(title: "Noticing calls") {
            SettingRow(
                title: "When a call starts",
                detail: "Zoom, Teams, FaceTime, Slack or Meet. Alfie never listens to decide — it asks which app has the microphone."
            ) {
                SettingMenu(value: conductor.config.meetingAutoDetect.label) {
                    Picker("", selection: Binding(
                        get: { conductor.config.meetingAutoDetect },
                        set: { conductor.setMeetingAutoDetect($0) })) {
                        ForEach(DetectMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.inline)
                }
            }
            // Its own switch, not part of the menu above. Starting a
            // recording is a decision about consent and belongs to the
            // person; stopping one they already started is tidying up, and
            // while it waited to be asked the file went on growing with
            // silence and the panel sat there wanting an answer.
            SettingRow(
                title: "When the call ends",
                detail: "Stop, save, and write the notes without asking. Off, Alfie offers to stop and waits.",
                last: ignored.isEmpty
            ) {
                VoicePane.lever(Binding(
                    get: { conductor.config.meetingAutoStopOnCallEnd },
                    set: { conductor.setMeetingAutoStopOnCallEnd($0) }))
            }
            ForEach(Array(ignored.enumerated()), id: \.element) { i, id in
                SettingRow(title: "Never for \(CallApps.match(bundleID: id)?.name ?? id)",
                           last: i == ignored.count - 1) {
                    PaneButton(title: "Ask again") { conductor.forgetIgnoredCallApp(id) }
                }
            }
        }
    }

    // MARK: - Pictures of the screen

    private var pictures: some View {
        SettingGroup(title: "Pictures of the screen") {

            SettingRow(
                title: "Screenshots",
                detail: "⌃⌥S takes one. They go in the meeting's notes."
            ) {
                modeMenu(policy.screenshots) { v in conductor.setMeetingCapture { $0.screenshots = v } }
            }
            if policy.screenshots == .auto || policy.recording == .auto {
                Calm.Reveal {
                    SettingRow(title: "By itself means", detail: cueSummary) {
                        PaneButton(title: "Choose…") { showCues = true }
                    }
                }
            }
            SettingRow(
                title: "Screen recordings",
                detail: "Up to \(Int(policy.clipMaxSeconds / 60)) minutes. ⌃⌥R starts and stops one."
            ) {
                modeMenu(policy.recording) { v in conductor.setMeetingCapture { $0.recording = v } }
            }
            SettingRow(title: "What the pictures show", last: policy.scope != .region) {
                SettingMenu(value: policy.scope.label) {
                    Picker("", selection: Binding(
                        get: { policy.scope },
                        set: { v in conductor.setMeetingCapture { $0.scope = v } })) {
                        ForEach(CaptureScope.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.inline)
                }
            }
            if policy.scope == .region {
                SettingRow(title: "The area",
                           detail: policy.region.map { "\(Int($0.width)) × \(Int($0.height)) pixels" } ?? "Not chosen yet.",
                           last: true) {
                    PaneButton(title: policy.region == nil ? "Choose the area…" : "Change the area…", symbol: "crop") {
                        conductor.chooseCaptureRegion()
                    }
                }
            }

            if !ScreenPermission.granted, policy.isEnabled {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
                    Text("Screen Recording isn't allowed for Alfie yet.")
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.warn)
                    Spacer(minLength: Theme.Space.small)
                    // Ask macOS first, then open Settings. System Settings
                    // lists an app under Screen Recording only after that
                    // app has asked once; this button used to deep-link
                    // straight there, and the owner opened the pane and
                    // found no Moe in it (2026-09-11). The ask registers
                    // Moe and raises the system dialog; if the dialog was
                    // refused before, macOS shows nothing and returns false,
                    // and the deep link is the way in — Moe is listed now.
                    PaneButton(title: "Allow…") { ScreenPermission.allow() }
                }
                .padding(.top, Theme.Space.base)
            }
        }
    }

    private func modeMenu(_ value: CaptureMode, set: @escaping (CaptureMode) -> Void) -> some View {
        SettingMenu(value: value.label) {
            Picker("", selection: Binding(get: { value }, set: set)) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.inline)
        }
    }

    private var cueSummary: String {
        let n = policy.cues.count
        let all = CaptureCue.allCases.count
        let which = n == all ? "any of the \(all) cues" : (n == 1 ? "one cue" : "\(n) of the \(all) cues")
        return "On \(which), at most one picture every \(Int(policy.minGapSeconds)) seconds."
    }
}

/// What "automatically" listens for: the phrases and moments in the
/// conversation that make Moe take a picture without being asked.
struct CaptureCuesSheet: View {
    @ObservedObject var conductor: Conductor
    let close: () -> Void

    private var policy: CapturePolicy { conductor.config.meetingCapture }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cosy) {
            Text("What counts as something being shown")
                .font(Theme.Typo.heading(20))
                .foregroundStyle(Theme.ink)
            Text("These are moments in the conversation — “let me share my screen”, “as you can see”, “we agreed” — that make Alfie take a picture by itself. At most one every \(Int(policy.minGapSeconds)) seconds and \(policy.maxAutoShots) per meeting. A clip that starts this way ends after \(Int(policy.clipMaxSeconds / 60)) minutes, \(Int(policy.clipIdleSeconds)) seconds after the last cue, or when someone says “stop sharing”.")
                .font(Theme.Typo.prose(13))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(CaptureCue.allCases.enumerated()), id: \.element) { i, cue in
                    SettingRow(title: cue.label, last: false) {
                        VoicePane.lever(Binding(
                            get: { policy.wants(cue) },
                            set: { on in conductor.setMeetingCapture { p in
                                p.cues.removeAll { $0 == cue }
                                if on { p.cues.append(cue) }
                            } }))
                    }
                }
                SettingRow(
                    title: "Ask my AI what each picture shows",
                    detail: "A one-line caption for the notes. The picture goes to your AI only while “Summarise with your AI” is on for the meeting.",
                    last: true
                ) {
                    VoicePane.lever(Binding(
                        get: { policy.caption },
                        set: { v in conductor.setMeetingCapture { $0.caption = v } }))
                }
            }
            HStack {
                Spacer()
                PaneButton(title: "Done", prominent: true, action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.wide)
        .frame(width: 560)
        .background(Theme.raised)
    }
}
