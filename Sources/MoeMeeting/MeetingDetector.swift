import Foundation

// "Looks like you're on a call — record it?"
//
// How Moe knows: Core Audio's process objects say which app has an input
// stream open (`kAudioProcessPropertyIsRunningInput`), with its bundle id.
// That is the same signal Granola, Notion and Circleback describe in their
// docs ("detects when an app like Zoom starts using your microphone"), it
// needs no permission, and it names the app — which the orange dot in the
// menu bar, the only thing a person sees, does not. Nothing here listens
// to any audio: the question asked of the system is "is Zoom's microphone
// open", never "what is being said into it".
//
// Browsers are the hard case. Chrome with the microphone open is a Meet
// call, or a dictation site, or a game; so a browser has to hold the mic
// *and* play audio for longer before Moe asks, and a calendar event
// happening now shortens that wait. A native call app is trusted sooner.
//
// This file is the rule; the app's `MeetingWatcher` feeds it every few
// seconds and shows the offer. Pure, so the whole state machine is tested
// with synthetic signals.

// MARK: - Which apps are calls

public struct CallApp: Equatable, Hashable, Sendable {
    public enum Kind: Sendable { case call, browser }

    public let bundleID: String
    public let name: String
    public let kind: Kind
    /// "Huddle detected" for Slack, "Call detected" for FaceTime — the
    /// word the app itself uses (Granola's touch).
    public let noun: String

    public init(bundleID: String, name: String, kind: Kind, noun: String = "call") {
        self.bundleID = bundleID; self.name = name; self.kind = kind; self.noun = noun
    }
}

public enum CallApps {
    public static let known: [CallApp] = [
        CallApp(bundleID: "us.zoom.xos", name: "Zoom", kind: .call, noun: "meeting"),
        CallApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", kind: .call, noun: "meeting"),
        CallApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams", kind: .call, noun: "meeting"),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime", kind: .call),
        CallApp(bundleID: "com.apple.Phone", name: "Phone", kind: .call),
        CallApp(bundleID: "com.apple.telephonyutilities.callservicesd", name: "Phone", kind: .call),
        CallApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex", kind: .call, noun: "meeting"),
        CallApp(bundleID: "Cisco-Systems.Spark", name: "Webex", kind: .call, noun: "meeting"),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", kind: .call, noun: "huddle"),
        CallApp(bundleID: "com.hnc.Discord", name: "Discord", kind: .call),
        CallApp(bundleID: "com.skype.skype", name: "Skype", kind: .call),
        CallApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", kind: .call),
        // The messengers people take voice calls on. A Telegram call on
        // 2026-09-02 was never noticed, and the recording that was started
        // by hand lost its microphone the moment the call took it: neither
        // could be explained while Telegram was not on this list.
        CallApp(bundleID: "com.tdesktop.Telegram", name: "Telegram", kind: .call),
        CallApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram", kind: .call),
        CallApp(bundleID: "org.telegram.desktop", name: "Telegram", kind: .call),
        CallApp(bundleID: "org.whispersystems.signal-desktop", name: "Signal", kind: .call),
        CallApp(bundleID: "com.viber.osx", name: "Viber", kind: .call),
        CallApp(bundleID: "com.google.meet", name: "Google Meet", kind: .call, noun: "meeting"),
        CallApp(bundleID: "com.loom.desktop", name: "Loom", kind: .call, noun: "recording"),
        CallApp(bundleID: "com.around.app", name: "Around", kind: .call, noun: "meeting"),
        CallApp(bundleID: "com.gather.desktop", name: "Gather", kind: .call, noun: "meeting"),
        CallApp(bundleID: "ai.tuple.app", name: "Tuple", kind: .call),
        CallApp(bundleID: "com.pop.pop.app", name: "Pop", kind: .call),
        CallApp(bundleID: "org.jitsi.jitsi-meet", name: "Jitsi", kind: .call, noun: "meeting"),
        CallApp(bundleID: "com.google.Chrome", name: "Chrome", kind: .browser),
        CallApp(bundleID: "com.google.Chrome.canary", name: "Chrome", kind: .browser),
        CallApp(bundleID: "com.apple.Safari", name: "Safari", kind: .browser),
        CallApp(bundleID: "com.apple.WebKit", name: "Safari", kind: .browser),
        CallApp(bundleID: "company.thebrowser.Browser", name: "Arc", kind: .browser),
        CallApp(bundleID: "company.thebrowser.dia", name: "Dia", kind: .browser),
        CallApp(bundleID: "com.brave.Browser", name: "Brave", kind: .browser),
        CallApp(bundleID: "org.mozilla.firefox", name: "Firefox", kind: .browser),
        CallApp(bundleID: "com.microsoft.edgemac", name: "Edge", kind: .browser),
        CallApp(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", kind: .browser),
        CallApp(bundleID: "com.operasoftware.Opera", name: "Opera", kind: .browser),
        CallApp(bundleID: "ai.perplexity.comet", name: "Comet", kind: .browser),
        CallApp(bundleID: "com.openai.atlas", name: "Atlas", kind: .browser),
    ]

    /// The app for a bundle id, including its helpers: Chrome's audio runs
    /// in `com.google.Chrome.helper`, Safari's in `com.apple.WebKit.GPU`,
    /// and the process object carries the helper's id, not the app's.
    public static func match(bundleID: String) -> CallApp? {
        guard !bundleID.isEmpty else { return nil }
        if let exact = known.first(where: { $0.bundleID == bundleID }) { return exact }
        return known.first { bundleID.hasPrefix($0.bundleID + ".") }
    }

    /// The call apps among these signals that have the microphone open,
    /// in signal order, each once. Anything that is not a call app —
    /// Siri's listener, a dictation helper — holds the microphone all day
    /// and is not what this asks about.
    public static func onMicrophone(_ signals: [CallSignal]) -> [CallApp] {
        var seen: [CallApp] = []
        for s in signals where s.input {
            guard let app = match(bundleID: s.bundleID), !seen.contains(app) else { continue }
            seen.append(app)
        }
        return seen
    }

    /// `onMicrophone` against Core Audio right now. Empty when the process
    /// list cannot be read — the safe answer for what this gates.
    public static func holdingMicrophone() -> [CallApp] {
        onMicrophone(ProcessList.Signals.current())
    }
}

// MARK: - The signal

/// One process, as Core Audio reports it.
public struct CallSignal: Equatable, Sendable {
    public var bundleID: String
    public var input: Bool
    public var output: Bool

    public init(bundleID: String, input: Bool, output: Bool) {
        self.bundleID = bundleID; self.input = input; self.output = output
    }
}

/// Off; ask on the island; or start the meeting the moment a call is
/// certain (the consent sheet still applies unless it, too, is off).
public enum DetectMode: String, Codable, CaseIterable, Sendable {
    case off, ask, auto

    public var label: String {
        switch self {
        case .off: return "Don't notice calls"
        case .ask: return "Offer to record"
        case .auto: return "Start recording"
        }
    }
}

// MARK: - The rule

public struct MeetingDetector: Equatable, Sendable {

    public struct Verdict: Equatable, Sendable {
        public enum Kind: Sendable { case started, ended }
        public var app: CallApp
        public var kind: Kind
    }

    /// How long a native call app must hold the microphone. Short: a
    /// dedicated call app holding the mic is not ambiguous, only a blip
    /// (a notification sound) is worth waiting out.
    public var holdSeconds: Double = 2
    /// How long a browser holding the microphone *alone* — no camera, no
    /// audio out, no calendar event — must hold it. The one slow case,
    /// because a browser with only the mic could be a dictation site.
    public var browserHoldSeconds: Double = 12
    /// A browser holding the microphone *and corroborated* — the camera is
    /// on, or it is playing call audio, or the calendar says a meeting is
    /// on now. Any one of those and it is a video call, not dictation, so
    /// the wait is short.
    public var browserHoldWithEventSeconds: Double = 3
    /// Microphone released for this long: the call is over. Long enough
    /// that a reconnect, a device switch or a "you're on mute" toggle
    /// does not end it.
    public var endAfterSeconds: Double = 25

    private struct Candidate: Equatable { var app: CallApp; var since: Double }
    private struct Active: Equatable { var app: CallApp; var quietSince: Double?; var dismissed: Bool }

    private var candidate: Candidate?
    private var active: Active?
    /// The last `t` a poll was observed at, to notice a gap (a sleep) and
    /// not let it satisfy a hold or an end for free.
    private var lastObservedAt: Double?
    /// A poll gap longer than this is a discontinuity (the Mac slept): the
    /// candidate's clock and any pending end are pushed to now rather than
    /// counting the gap as elapsed. Far above the 4 s poll cadence and the
    /// 25 s end window, so only a real stall (a sleep is minutes) trips it.
    public var staleGapSeconds: Double = 90

    public init() {}

    /// The call Moe believes is on, if any.
    public var current: CallApp? { active?.app }

    /// The user said "not this one": stay quiet until this call ends, and
    /// say nothing when it does.
    public mutating func dismiss() {
        active?.dismissed = true
    }

    /// The meeting is being recorded (the offer was taken, or it was
    /// started by hand while this call was on). Deliberately a no-op on the
    /// verdict: the call is still *active*, so when it ends the `.ended`
    /// verdict must still fire — that is what offers to stop and writes the
    /// notes. It was `dismissed = true` once, which killed the end offer for
    /// every recorded meeting; the reason no *start* offer appears over a
    /// recording is `Conductor`'s own "meeting not idle" guard, not this.
    public mutating func acknowledge() {}

    /// One poll. `ignored` are bundle ids the user turned off ("Never for
    /// Slack"); `calendarNow` is whether an event with other people is on;
    /// `cameraOn` is whether any app is using the camera right now (a
    /// system-wide signal — see `CameraProbe` — so it corroborates a
    /// browser candidate rather than naming one).
    public mutating func observe(_ signals: [CallSignal], ignored: Set<String> = [],
                                 calendarNow: Bool = false, cameraOn: Bool = false,
                                 at t: Double) -> Verdict? {
        // A large gap since the last poll is the Mac having slept: the
        // wall clock jumped, but no call was observed across it. Don't let
        // that gap satisfy a hold (a false "detected") or an end (a false
        // "seems to have ended") — reset the candidate's clock, and push any
        // pending end to now.
        if let last = lastObservedAt, t - last > staleGapSeconds {
            candidate = nil
            if active?.quietSince != nil { active?.quietSince = t }
        }
        lastObservedAt = t

        let apps = Self.appsWithMic(signals, ignored: ignored)

        if var live = active {
            let still = apps.contains { $0.app == live.app }
            if still {
                if live.quietSince != nil { live.quietSince = nil; active = live }
                return nil
            }
            if live.quietSince == nil {
                live.quietSince = t
                active = live
                return nil
            }
            guard t - live.quietSince! >= endAfterSeconds else { return nil }
            active = nil
            candidate = nil
            return live.dismissed ? nil : Verdict(app: live.app, kind: .ended)
        }

        // Nothing active: a native call app that holds the microphone, or
        // any browser that holds it. A browser no longer needs to be
        // playing sound to be a candidate — a solo call, or one where the
        // others are muted, has no audio out, and that was the whole miss:
        // it just waits longer unless something corroborates it.
        guard let pick = apps.first(where: { $0.app.kind == .call })
                ?? apps.first(where: { $0.app.kind == .browser }) else {
            candidate = nil
            return nil
        }
        if candidate?.app != pick.app {
            candidate = Candidate(app: pick.app, since: t)
            return nil
        }
        let need: Double
        switch pick.app.kind {
        case .call:
            need = holdSeconds
        case .browser:
            // Corroborated — camera on, playing call audio, or a calendar
            // event now — it is a video call: the short wait. Mic alone: the
            // long one, in case it is dictation.
            let corroborated = cameraOn || pick.output || calendarNow
            need = corroborated ? browserHoldWithEventSeconds : browserHoldSeconds
        }
        guard t - candidate!.since >= need else { return nil }
        active = Active(app: pick.app, quietSince: nil, dismissed: false)
        candidate = nil
        return Verdict(app: pick.app, kind: .started)
    }

    /// Known apps with an input stream open, one entry per app (its
    /// helpers folded in), `output` true if any of its processes plays.
    public static func appsWithMic(_ signals: [CallSignal], ignored: Set<String> = []) -> [(app: CallApp, output: Bool)] {
        var out: [(app: CallApp, output: Bool)] = []
        for s in signals {
            guard let app = CallApps.match(bundleID: s.bundleID), !ignored.contains(app.bundleID) else { continue }
            let plays = signals.contains { CallApps.match(bundleID: $0.bundleID) == app && $0.output }
            guard s.input else { continue }
            if let i = out.firstIndex(where: { $0.app == app }) {
                out[i].output = out[i].output || plays
            } else {
                out.append((app, plays))
            }
        }
        return out
    }
}

/// The words on the island when a call is noticed.
public enum MeetingOfferText {
    /// "Zoom meeting detected — record it?"
    public static func title(_ app: CallApp) -> String {
        "\(app.name) \(app.noun) detected"
    }

    public static func body(_ app: CallApp, mode: DetectMode, countdown: Int?) -> String {
        switch mode {
        case .auto:
            if let countdown, countdown > 0 {
                return "Recording starts in \(countdown) s — Moe will take the notes. Click to stop it."
            }
            return "Recording — Moe is taking the notes."
        case .ask, .off:
            return "Record it? Moe takes the notes; everyone on the \(app.noun) should know."
        }
    }

    /// "Never for Slack"
    public static func never(_ app: CallApp) -> String { "Never for \(app.name)" }

    /// After the call: "Your Zoom meeting seems to have ended."
    public static func ended(_ app: CallApp) -> String {
        "Your \(app.name) \(app.noun) seems to have ended — stop recording and write the notes?"
    }
}
