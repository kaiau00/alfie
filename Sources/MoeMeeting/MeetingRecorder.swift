import AVFoundation
import Foundation

/// Records a meeting: the call's audio through a Core Audio process tap
/// (everything but this process, a tap-only aggregate so it survives the
/// mic's voice processing) and the room through the mic with echo
/// cancellation and ducking off — the recipe MEETING-MODE.md proved.
///
/// Both streams go to 16 kHz mono 16-bit WAVs in `folder`, written as they
/// arrive, padded with leading silence from one shared epoch so `t = 0`
/// means the same instant in both. Nothing is kept in RAM.
public final class MeetingRecorder {

    public enum Stream: String, CaseIterable, Sendable { case system, mic }

    public struct Levels: Sendable {
        public var systemDb: Float
        public var micDb: Float
        public var systemFrames: Int
        public var micFrames: Int
    }

    public let folder: URL
    public let epoch: Date
    public let systemURL: URL
    public let micURL: URL
    private(set) public var systemSink: SampleSink?
    private(set) public var micSink: SampleSink?
    private var tap: ProcessTap?
    private(set) public var mic: MicCapture?
    private(set) public var startedAt: Date?
    private(set) public var stoppedAt: Date?

    /// `~/.moe/meetings/<yyyy-mm-dd-HHMM>/` (0700), or a subfolder of `base`.
    /// If the minute's folder already exists a suffix keeps them apart.
    public static func makeFolder(base: URL, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var name = MeetingFolder.name(for: date)
        var url = base.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = base.appendingPathComponent("\(name)-\(n)", isDirectory: true); n += 1
        }
        name = url.lastPathComponent
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    public init(folder: URL, epoch: Date = Date()) {
        self.folder = folder
        self.epoch = epoch
        systemURL = folder.appendingPathComponent("system.wav")
        micURL = folder.appendingPathComponent("mic.wav")
    }

    /// Opens both files and starts capture. Start order matters: enabling
    /// voice processing on the mic engine reconfigures the hardware device,
    /// which kills a tap aggregate that is already running on it — so the
    /// mic goes first, then the tap. On any failure everything already
    /// started is stopped and the error is rethrown (a tap creation failure
    /// is how a denied System Audio Recording grant may show up; silence
    /// with the IO proc ticking is the other way — see `tapIsDelivering`).
    public func start(target: TapTarget = .allExceptSelf, echoCancel: Bool = true) throws {
        let systemSink = try SampleSink(url: systemURL, epoch: epoch)
        let micSink = try SampleSink(url: micURL, epoch: epoch)
        self.systemSink = systemSink
        self.micSink = micSink
        self.target = target
        let mic = MicCapture(sink: micSink, echoCancel: echoCancel)
        let tap = ProcessTap(target: target, sink: systemSink)
        do {
            try mic.start()
            self.mic = mic
            try tap.start()
            self.tap = tap
        } catch {
            stop()
            throw error
        }
        startedAt = Date()
    }

    /// What the tap was pointed at, kept so it can be rebuilt.
    private var target: TapTarget = .allExceptSelf

    /// Stops capture and closes both files (headers patched). Idempotent.
    public func stop() {
        guard stoppedAt == nil else { return }
        if isPaused { pauses.resume(at: elapsed) }
        tap?.stop(); tap = nil
        mic?.stop(); mic = nil
        systemSink?.close()
        micSink?.close()
        stoppedAt = Date()
    }

    public var isRecording: Bool { startedAt != nil && stoppedAt == nil }

    // MARK: Off the record

    private(set) public var pauses = PauseLog()
    public var isPaused: Bool { pauses.isOpen }

    /// Off the record: both sinks write silence until `resume`. Audio and
    /// text of the stretch are gone — nothing reaches the files or the
    /// recogniser — and the stretch is noted in the record.
    public func pause() {
        guard isRecording, !isPaused else { return }
        systemSink?.muted = true
        micSink?.muted = true
        pauses.pause(at: elapsed)
    }

    public func resume() {
        guard isPaused else { return }
        systemSink?.muted = false
        micSink?.muted = false
        pauses.resume(at: elapsed)
    }

    /// Seconds since the epoch both files are padded from.
    public var elapsed: Double { (stoppedAt ?? Date()).timeIntervalSince(epoch) }

    /// Current levels (dBFS since the last call) and frames written so far.
    public func levels() -> Levels {
        let s = systemSink?.meter.drain() ?? (rms: -200, peak: -200, frames: 0)
        let m = micSink?.meter.drain() ?? (rms: -200, peak: -200, frames: 0)
        return Levels(systemDb: s.rms, micDb: m.rms,
                      systemFrames: systemSink?.count ?? 0, micFrames: micSink?.count ?? 0)
    }

    /// Hand the mic's 16 kHz buffers to a second consumer (the app's
    /// recogniser during a whispered question); nil detaches. No-op when
    /// the mic is not running.
    public func forwardMic(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        mic?.forward.handler = handler
    }

    /// Frames written so far for one stream (leading silence included).
    public func frames(_ stream: Stream) -> Int {
        (stream == .system ? systemSink : micSink)?.count ?? 0
    }

    public func url(_ stream: Stream) -> URL { stream == .system ? systemURL : micURL }

    /// The IO proc is running and has delivered at least one buffer. False
    /// with callbacks ticking is the signature of a tap without the System
    /// Audio Recording grant (macOS delivers silence, not an error) — or of
    /// a call app that is not playing anything yet, so the caller decides
    /// how long to wait before reading it as "denied".
    public var tapIsDelivering: Bool { (systemSink?.buffers ?? 0) > 0 }
    public var tapCallbacks: Int { tap?.ioCallbacks ?? 0 }

    // MARK: - Is the tap carrying anything?
    //
    // `tapIsDelivering` counts buffers, and both ways a process tap dies
    // keep the buffers coming: with a hardware sub-device and voice
    // processing running in this process the IO proc ticks with zero
    // frames, and without one it ticks with frames of exact zeros. On
    // 2026-09-08 that second failure wrote 59,153,310 silent frames across
    // a 61-minute call and nothing noticed. `TapWatch` is the rule; these
    // are the facts it needs.

    /// Whether the call-audio stream has carried a sample with a value in
    /// it since the tap was last built.
    public var systemHasSound: Bool { systemSink?.hasSound ?? false }
    /// Whether voice processing is actually running on the microphone.
    public var isEchoCancelling: Bool { mic?.echoCancel ?? false }

    /// Give up echo cancellation for the rest of the meeting and rebuild
    /// the microphone without it — the measured cause of a silent tap.
    /// Returns the line to log, or nil when it was already off.
    public func dropEchoCancellation() -> String? { mic?.dropEchoCancellation() }

    /// Destroy the process tap and its aggregate device and build both
    /// again on the same sink.
    ///
    /// Both, together: a tap that has gone to all-zeros mid-session is not
    /// restored by restarting the IO proc or by recreating the aggregate
    /// alone. The sink is padded to the wall clock first, so the seconds
    /// the dead tap missed stay in the file as silence rather than
    /// shortening it and pulling every later timestamp forward.
    public func rebuildTap() -> String {
        guard isRecording, let sink = systemSink else { return "system tap not rebuilt — not recording" }
        let padded = sink.padToNow()
        tap?.stop()
        tap = nil
        sink.forgetSound()
        let fresh = ProcessTap(target: target, sink: sink)
        do {
            try fresh.start()
            tap = fresh
            let gap = padded > 0 ? String(format: ", %.1f s of silence bridged", Double(padded) / meetingSampleRate) : ""
            return "system tap rebuilt on \(fresh.targetDescription)\(gap)"
        } catch {
            return "system tap rebuild failed: \(error)"
        }
    }

    /// What was opened, in words, once `start` has returned: the microphone
    /// device and format, and what the system tap is pointed at. Logged at
    /// meeting start — the two facts that decide whether a meeting could
    /// have heard anything at all, and neither was recorded anywhere.
    public var micDescription: String { mic?.description ?? "no microphone" }

    /// Every channel of the microphone's raw bus, measured. The one thing
    /// that can say whether the channel being recorded is the microphone.
    public func micChannelReport() -> ChannelReport? { mic?.channelReport() }

    /// Rebuilds the microphone input if it has stopped delivering. Call
    /// on a timer; returns the line to log when it did something.
    public func micWatchdog() -> String? { mic?.watchdog() }
    public var tapDescription: String { tap?.targetDescription ?? "no system tap" }

    /// How the two clocks compare, once stopped.
    public var drift: DriftReport {
        DriftReport(systemFrames: frames(.system), micFrames: frames(.mic), wallSeconds: elapsed)
    }
}
