import Foundation
import MoeMeeting

/// Polls Core Audio's process list every few seconds and runs
/// `MeetingDetector` over it — the rule is in the library and tested; this
/// is the timer. One property read per process, no audio touched, no
/// permission asked. The calendar is consulted only while something
/// *might* be a call, and at most once a minute, because EventKit is the
/// expensive half.
@MainActor
final class MeetingWatcher {
    /// The poll cadence. Fast, because it is what sets how quickly a call is
    /// noticed — at 4 s the offer trailed the mic opening by up to a poll on
    /// top of the hold, which read as sluggish next to Wispr. One process
    /// list read plus, only while a browser holds the mic, one camera
    /// property read per device: cheap enough to run this often.
    ///
    /// The read itself goes through `ProcessList.Signals`, which is shared
    /// with `AudioFrontEnd`'s 2 s call watch and cached just under this
    /// interval — so this poll always gets a fresh answer and the other
    /// caller stops paying for a second one.
    static let interval: TimeInterval = 1.5
    static let calendarEvery: TimeInterval = 60

    var onVerdict: ((MeetingDetector.Verdict) -> Void)?
    /// Bundle ids the user turned off, read on every tick so "Never for
    /// Slack" applies at once.
    var ignored: () -> Set<String> = { [] }

    private var timer: Timer?
    private var detector = MeetingDetector()
    private var calendarNow = false
    private var calendarCheckedAt: Date?
    private var polling = false
    private var lastHeldFingerprint = ""
    private let epoch = Date()

    var current: CallApp? { detector.current }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        detector = MeetingDetector()
    }

    /// The meeting is recording by another route: no offer for this call.
    func acknowledge() { detector.acknowledge() }
    /// "Not this one."
    func dismiss() { detector.dismiss() }

    private func poll() {
        guard !polling else { return }
        polling = true
        let ignored = ignored()
        Task { [weak self] in
            let signals = await Task.detached(priority: .utility) {
                ProcessList.Signals.current()
            }.value
            guard let self else { return }
            self.polling = false
            // Only ask the calendar while a known app holds the microphone.
            let anyCandidate = signals.contains { $0.input && CallApps.match(bundleID: $0.bundleID) != nil }
            if anyCandidate, self.calendarCheckedAt.map({ Date().timeIntervalSince($0) > Self.calendarEvery }) ?? true {
                self.calendarCheckedAt = Date()
                self.calendarNow = await Task.detached(priority: .utility) { MeetingInvite.invite() != nil }.value
            } else if !anyCandidate {
                self.calendarNow = false
                self.calendarCheckedAt = nil
            }
            // The camera only matters while a browser holds the microphone —
            // it is what tells a Meet call from a dictation site — so it is
            // only read then, and it is cheap (a property read per device).
            let anyBrowser = signals.contains {
                $0.input && CallApps.match(bundleID: $0.bundleID)?.kind == .browser
            }
            let cameraOn = anyBrowser ? await Task.detached(priority: .utility) { CameraProbe.inUse() }.value : false
            // A line whenever a known app is holding the microphone but no
            // verdict came of it — the trail for "I was on a Meet and
            // nothing happened". Rate-limited to once per app-set so a
            // whole call is one or two lines, not one every four seconds.
            let held = MeetingDetector.appsWithMic(signals, ignored: ignored)
            let fingerprint = held.map { "\($0.app.bundleID):\($0.output ? "o" : "-")" }.sorted().joined(separator: ",")
                + (cameraOn ? "+cam" : "")
            if !held.isEmpty, fingerprint != self.lastHeldFingerprint {
                self.lastHeldFingerprint = fingerprint
                Log.write("meeting: mic held by " + held.map {
                    "\($0.app.name)\($0.output ? " (audio out)" : "")"
                }.joined(separator: ", ")
                    + (cameraOn ? ", camera on" : "") + (self.calendarNow ? ", calendar event on" : "")
                    + " — watching")
            } else if held.isEmpty {
                self.lastHeldFingerprint = ""
            }
            let t = Date().timeIntervalSince(self.epoch)
            if let v = self.detector.observe(signals, ignored: ignored, calendarNow: self.calendarNow,
                                             cameraOn: cameraOn, at: t) {
                Log.write("meeting: \(v.app.name) \(v.app.noun) \(v.kind == .started ? "detected" : "ended")"
                          + (self.calendarNow ? " (calendar event on)" : "") + (cameraOn ? " (camera on)" : ""))
                self.onVerdict?(v)
            }
        }
    }
}
