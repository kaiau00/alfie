import AppKit
import AVFoundation
import CoreMedia
import Foundation
import MoeMeeting
import ScreenCaptureKit

// The pixels: one still, one clip, one dragged rectangle.
//
// The decisions (when, why, how many) are in `MoeMeeting/MeetingCapture.swift`
// and tested; this file is the ScreenCaptureKit and AVFoundation behind them.
// It is the second place in Moe that asks for Screen Recording — the first is
// the screen-context screenshot on a spoken turn — and shares that one TCC
// grant. Nothing here ever raises the system dialog on a timer: the request
// comes from a click in Settings or the first hotkey press, moments when a
// person is looking.

// MARK: - Permission

enum ScreenPermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// Raise the system dialog (once; after a refusal it opens nothing and
    /// returns false, so the caller deep-links instead).
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func openSettings() { NSWorkspace.shared.open(settingsURL) }

    /// The one call a settings button should make. Asks macOS, which is
    /// what puts Moe on the Screen Recording list at all, and opens that
    /// list if the ask did not end in a grant — after a refusal the dialog
    /// never shows again, and the toggle is the only way back.
    static func allow() {
        if !request() { openSettings() }
    }
}

// MARK: - Where to look

/// The content filter for a scope, built fresh for each capture because the
/// meeting window moves and displays come and go.
@MainActor
enum CaptureTarget {

    struct Resolved {
        let filter: SCContentFilter
        /// Points, top-left origin, global: what the filter covers.
        let frame: CGRect
        let backingScale: CGFloat
        /// Set when the scope asked for a region: the part of `frame` wanted.
        let sourceRect: CGRect?
        let note: String
    }

    /// `preferredApps`: bundle ids of the call app, if Moe knows it. The
    /// window scope picks that app's biggest on-screen window; with no
    /// known app, the biggest window of any known call app; failing that
    /// the frontmost app's biggest window — and says so in `note`.
    static func resolve(scope: CaptureScope, region: CaptureRegion?, preferredApps: [String]) async throws -> Resolved {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // No displays at all — the screen asleep, a display reconfiguration
        // in flight — is a "not now", never a crash: `displayUnderMouse`
        // and the region branch both index into this, and an auto cue can
        // fire at exactly such a moment.
        guard !content.displays.isEmpty else {
            throw MeetingSessionError("no display is available to capture right now")
        }
        let overlays = content.windows.filter {
            $0.owningApplication?.processID == getpid()
                && $0.windowLayer >= Int(CGWindowLevelForKey(.screenSaverWindow))
        }
        // Moe's own island and panels are never in a meeting picture.
        let ours = content.windows.filter { $0.owningApplication?.processID == getpid() }

        switch scope {
        case .window:
            if let w = meetingWindow(in: content.windows, preferredApps: preferredApps) {
                let filter = SCContentFilter(desktopIndependentWindow: w.window)
                return Resolved(filter: filter, frame: w.window.frame, backingScale: scale(for: w.window.frame, content),
                                sourceRect: nil, note: w.note)
            }
            fallthrough
        case .display:
            let display = displayUnderMouse(content.displays)
            let filter = SCContentFilter(display: display, excludingWindows: overlays + ours)
            let note = scope == .window ? "no meeting window found; whole screen" : ""
            return Resolved(filter: filter, frame: display.frame, backingScale: scale(for: display.frame, content),
                            sourceRect: nil, note: note)
        case .region:
            guard let region else {
                let display = displayUnderMouse(content.displays)
                return Resolved(filter: SCContentFilter(display: display, excludingWindows: overlays + ours),
                                frame: display.frame, backingScale: scale(for: display.frame, content),
                                sourceRect: nil, note: "no area chosen; whole screen")
            }
            let rect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
            // The display holding most of the rectangle.
            let display = content.displays.max {
                $0.frame.intersection(rect).area < $1.frame.intersection(rect).area
            } ?? displayUnderMouse(content.displays)
            let bounds = CaptureRegion(x: display.frame.minX, y: display.frame.minY,
                                       width: display.frame.width, height: display.frame.height)
            guard let inside = region.clamped(to: bounds) else {
                return Resolved(filter: SCContentFilter(display: display, excludingWindows: overlays + ours),
                                frame: display.frame, backingScale: scale(for: display.frame, content),
                                sourceRect: nil, note: "the chosen area is off screen; whole screen")
            }
            // `sourceRect` is in points relative to the display's own origin.
            let local = CGRect(x: inside.x - display.frame.minX, y: inside.y - display.frame.minY,
                               width: inside.width, height: inside.height)
            return Resolved(filter: SCContentFilter(display: display, excludingWindows: overlays + ours),
                            frame: display.frame, backingScale: scale(for: display.frame, content),
                            sourceRect: local, note: "")
        }
    }

    private static func meetingWindow(in windows: [SCWindow], preferredApps: [String]) -> (window: SCWindow, note: String)? {
        func biggest(_ ws: [SCWindow]) -> SCWindow? {
            ws.filter { $0.isOnScreen && $0.frame.width >= 200 && $0.frame.height >= 150 && $0.windowLayer == 0 }
              .max { $0.frame.area < $1.frame.area }
        }
        let preferred = Set(preferredApps)
        if !preferred.isEmpty, let w = biggest(windows.filter {
            guard let b = $0.owningApplication?.bundleIdentifier else { return false }
            return preferred.contains(b) || CallApps.match(bundleID: b).map { preferred.contains($0.bundleID) } == true
        }) { return (w, "") }
        // Any native call app; browsers are too ambiguous to guess a window of.
        if let w = biggest(windows.filter {
            guard let b = $0.owningApplication?.bundleIdentifier, let app = CallApps.match(bundleID: b) else { return false }
            return app.kind == .call
        }) { return (w, "") }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
           let w = biggest(windows.filter { $0.owningApplication?.processID == front.processIdentifier }) {
            return (w, "no meeting window found; the front window (\(front.localizedName ?? "?"))")
        }
        return nil
    }

    static func displayUnderMouse(_ displays: [SCDisplay]) -> SCDisplay {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        return displays.first { $0.frame.contains(cg) } ?? displays[0]
    }

    private static func scale(for frame: CGRect, _ content: SCShareableContent) -> CGFloat {
        let display = content.displays.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
        let id = display?.displayID
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }?.backingScaleFactor ?? 2
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

// MARK: - A still

enum MeetingScreenshot {
    /// Archival size: bigger than the 1568 px the model sees, small enough
    /// that sixty of them are a few megabytes.
    static let maxSide = 2200
    static let quality: CGFloat = 0.82

    struct Result {
        let image: CGImage
        let note: String
    }

    @MainActor
    static func take(scope: CaptureScope, region: CaptureRegion?, preferredApps: [String]) async throws -> Result {
        let target = try await CaptureTarget.resolve(scope: scope, region: region, preferredApps: preferredApps)
        let cfg = SCStreamConfiguration()
        let src = target.sourceRect ?? CGRect(origin: .zero, size: target.frame.size)
        if let rect = target.sourceRect { cfg.sourceRect = rect }
        let px = (Int(src.width * target.backingScale), Int(src.height * target.backingScale))
        let (w, h) = fit(px.0, px.1, maxSide: maxSide)
        cfg.width = w
        cfg.height = h
        cfg.showsCursor = false
        cfg.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: cfg)
        return Result(image: image, note: target.note)
    }

    /// JPEG bytes at `quality`, resized to `maxSide` if larger.
    nonisolated static func jpeg(_ image: CGImage, maxSide: Int = MeetingScreenshot.maxSide, quality: CGFloat = MeetingScreenshot.quality) -> Data? {
        let (w, h) = fit(image.width, image.height, maxSide: maxSide)
        var cg = image
        if w != image.width || h != image.height {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            cg = scaled
        }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    nonisolated static func fit(_ w: Int, _ h: Int, maxSide: Int) -> (Int, Int) {
        let longest = max(w, h)
        guard longest > maxSide, longest > 0 else { return (max(w, 1), max(h, 1)) }
        let f = Double(maxSide) / Double(longest)
        return (max(Int(Double(w) * f), 1), max(Int(Double(h) * f), 1))
    }

    /// Write `data` to `folder/relative`, creating `shots/` or `clips/`,
    /// owner-only like everything else in a meeting folder.
    nonisolated static func write(_ data: Data, to folder: URL, relative: String) throws -> URL {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

// MARK: - A clip

/// A silent H.264 clip of the same target, at a modest frame rate. Silent
/// because the meeting's audio is already on disk as the two WAVs and in
/// the transcript; a clip is for what was *shown*.
///
/// Two objects on purpose: this one, on the main actor, owns the stream
/// and the API; `ClipSink`, confined to the stream's handler queue, owns
/// the writer and is the only thing that touches it while frames arrive.
@MainActor
final class MeetingClipRecorder {
    static let fps = 10
    static let maxWidth = 1920

    private var stream: SCStream?
    private var sink: ClipSink?
    private let queue = DispatchQueue(label: "moe.meeting.clip")
    private(set) var url: URL?
    private(set) var startedAt: Date?
    private(set) var note = ""
    private(set) var failure: String?
    /// The capture stream died on its own (Screen Recording revoked, the
    /// display unplugged): whoever owns the recorder is told to finalize,
    /// so a user- or agent-started clip does not stay "recording" forever.
    var onDied: (() -> Void)?

    var isRunning: Bool { stream != nil }

    func start(to url: URL, scope: CaptureScope, region: CaptureRegion?, preferredApps: [String]) async throws {
        guard stream == nil else { return }
        let target = try await CaptureTarget.resolve(scope: scope, region: region, preferredApps: preferredApps)
        note = target.note
        let cfg = SCStreamConfiguration()
        let src = target.sourceRect ?? CGRect(origin: .zero, size: target.frame.size)
        if let rect = target.sourceRect { cfg.sourceRect = rect }
        let px = (Int(src.width * target.backingScale), Int(src.height * target.backingScale))
        var (w, h) = MeetingScreenshot.fit(px.0, px.1, maxSide: Self.maxWidth)
        // H.264 wants even dimensions.
        w -= w % 2; h -= h % 2
        cfg.width = max(w, 2)
        cfg.height = max(h, 2)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.fps))
        cfg.showsCursor = true
        cfg.queueDepth = 6
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.capturesAudio = false

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: url)
        let sink = try ClipSink(url: url, width: cfg.width, height: cfg.height, fps: Self.fps)
        sink.onDied = { [weak self] in
            Task { @MainActor in
                guard let self, self.stream != nil else { return }
                self.onDied?()
            }
        }
        let stream = SCStream(filter: target.filter, configuration: cfg, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.sink = sink
        self.url = url
        startedAt = Date()
        failure = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Stops and finishes the file. Returns the duration in seconds, or
    /// nil when nothing usable was written (the file is removed then).
    func stop() async -> Double? {
        guard let stream, let sink else { return nil }
        self.stream = nil
        self.sink = nil
        try? await stream.stopCapture()
        let outcome = await sink.finish(on: queue)
        switch outcome {
        case .written(let seconds):
            return seconds
        case .empty(let why):
            if let url { try? FileManager.default.removeItem(at: url) }
            failure = why
            return nil
        }
    }
}

/// The writer, confined to the SCStream handler queue. `finish` hops onto
/// that queue too, so nothing here is ever touched from two threads.
final class ClipSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Outcome { case written(seconds: Double), empty(String) }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int
    private var sessionStarted = false
    private var firstPTS: CMTime = .zero
    private var lastPTS: CMTime = .zero
    private var frames = 0
    private let lock = NSLock()
    private var _streamError: String?
    private var streamError: String? {
        get { lock.lock(); defer { lock.unlock() }; return _streamError }
        set { lock.lock(); _streamError = newValue; lock.unlock() }
    }
    /// The stream stopped on its own. Set once, on the delegate queue.
    var onDied: (() -> Void)?

    init(url: URL, width: Int, height: Int, fps: Int) throws {
        self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        super.init()
        guard writer.canAdd(input) else { throw MeetingSessionError("the clip writer refused its input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw MeetingSessionError("could not start the clip: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, writer.status == .writing else { return }
        // Only complete frames carry a picture; idle and blank ones do not.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstPTS = pts
        }
        guard input.isReadyForMoreMediaData else { return }
        if adaptor.append(pixels, withPresentationTime: pts) {
            lastPTS = pts
            frames += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamError = error.localizedDescription
        onDied?()
    }

    /// Called once, after `stopCapture` returned, on the handler queue.
    func finish(on queue: DispatchQueue) async -> Outcome {
        await withCheckedContinuation { c in
            queue.async {
                guard self.frames > 0, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    c.resume(returning: .empty(self.streamError ?? self.writer.error?.localizedDescription ?? "no frames arrived"))
                    return
                }
                self.input.markAsFinished()
                let seconds = max(CMTimeGetSeconds(CMTimeSubtract(self.lastPTS, self.firstPTS)), 1.0 / Double(self.fps))
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        c.resume(returning: .written(seconds: seconds))
                    } else {
                        c.resume(returning: .empty(self.writer.error?.localizedDescription ?? "the clip could not be finished"))
                    }
                }
            }
        }
    }
}

// MARK: - The command line

/// `Moe --meeting-capture …`: a file for the running app, an answer back.
/// The app polls once a second while a meeting records, so an answer
/// arrives within about a second; none in six means no meeting (or no Moe).
enum MeetingCaptureCLI {
    static let wait: TimeInterval = 6

    static func run(_ argv: [String]) -> Int32 {
        guard let verb = argv.first else { return usage() }
        var command: [String: Any]
        switch verb {
        case "screenshot", "shot":
            command = ["action": "screenshot", "reason": argv.dropFirst().joined(separator: " ")]
        case "record", "clip":
            let rest = Array(argv.dropFirst())
            guard let which = rest.first, ["start", "stop"].contains(which) else { return usage() }
            command = ["action": "record", "start": which == "start", "reason": rest.dropFirst().joined(separator: " ")]
        case "status":
            command = ["action": "status"]
        default:
            return usage()
        }
        let cmdURL = Conductor.commandURL
        let resURL = Conductor.commandResultURL
        try? FileManager.default.createDirectory(at: cmdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: resURL)
        guard let data = try? JSONSerialization.data(withJSONObject: command),
              (try? data.write(to: cmdURL, options: .atomic)) != nil else {
            FileHandle.standardError.write(Data("could not write \(cmdURL.path)\n".utf8))
            return 1
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let out = try? Data(contentsOf: resURL),
               let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any] {
                try? FileManager.default.removeItem(at: resURL)
                let ok = (obj["ok"] as? Bool) ?? false
                var line = (obj["message"] as? String) ?? (ok ? "done" : "failed")
                if let file = obj["file"] as? String { line += " → \(file)" }
                if let list = obj["captures"] as? [String], !list.isEmpty { line += "\n" + list.joined(separator: "\n") }
                print(line)
                return ok ? 0 : 1
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try? FileManager.default.removeItem(at: cmdURL)
        print("Moe isn't recording a meeting right now, so there is nothing to capture. "
              + "Ask for one instead: write \u{003C}meeting:start/\u{003E} in your reply, "
              + "or the user can start one from the Moe menu.")
        return 2
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("""
        usage: Moe --meeting-capture screenshot [reason]
               Moe --meeting-capture record start|stop [reason]
               Moe --meeting-capture status

        """.utf8))
        return 64
    }
}

// MARK: - Smoke test

/// `Moe --capture-test <out-dir> [live]`: the still and clip writers over a
/// synthetic frame — no Screen Recording grant needed — and, with `live`,
/// one real screenshot per scope and a three-second clip of the display,
/// reporting sizes. For scripts/test-meeting-capture.sh. Exit 0 when every
/// file it promised exists.
@MainActor
enum MeetingCaptureSmokeTest {
    static func run(_ argv: [String]) async -> Int32 {
        @Sendable func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        guard let dir = argv.first else { err("usage: Moe --capture-test <out-dir> [live]"); return 64 }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        let live = argv.contains("live")
        var failures = 0

        // 1. A synthetic frame through the real encoder and writer.
        let w = 2560, h = 1600
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return 1 }
        ctx.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<400 {
            ctx.setFillColor(CGColor(red: Double(i % 7) / 7, green: Double(i % 11) / 11, blue: Double(i % 13) / 13, alpha: 1))
            ctx.fill(CGRect(x: (i % 20) * 128, y: (i / 20) * 80, width: 120, height: 72))
        }
        guard let image = ctx.makeImage(), let jpeg = MeetingScreenshot.jpeg(image) else { err("encode failed"); return 1 }
        let name = CaptureFile.name(index: 1, at: 32.4, kind: .screenshot, reason: "screen-share")
        do {
            let url = try MeetingScreenshot.write(jpeg, to: out, relative: name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
            let back = NSImage(contentsOf: url)
            err("synthetic: \(name) \(size) bytes, \(Int(back?.size.width ?? 0))×\(Int(back?.size.height ?? 0)) pt, mode \(String(perms, radix: 8))")
            if size < 10_000 || back == nil || perms != 0o600 { failures += 1 }
            if let rep = back?.representations.first, max(rep.pixelsWide, rep.pixelsHigh) > MeetingScreenshot.maxSide {
                err("synthetic: not downscaled (\(rep.pixelsWide)×\(rep.pixelsHigh))"); failures += 1
            }
        } catch { err("synthetic write failed: \(error)"); failures += 1 }
        let small = MeetingScreenshot.jpeg(image, maxSide: ScreenContext.maxSide, quality: 0.75)
        err("caption copy: \(small?.count ?? 0) bytes")
        if (small?.count ?? 0) == 0 { failures += 1 }
        print("synthetic \(failures == 0 ? "ok" : "FAILED")")

        guard live else { return failures == 0 ? 0 : 1 }

        // 2. Real captures: one still per scope, then a short clip.
        err("live: Screen Recording \(ScreenPermission.granted ? "granted" : "NOT granted — asking")")
        guard ScreenPermission.granted || ScreenPermission.request() else {
            err("live: no permission; grant it under Privacy & Security › Screen & System Audio Recording")
            return 3
        }
        for scope in CaptureScope.allCases {
            let region = scope == .region ? CaptureRegion(x: 100, y: 100, width: 640, height: 400) : nil
            do {
                let shot = try await MeetingScreenshot.take(scope: scope, region: region, preferredApps: [])
                let n = CaptureFile.name(index: CaptureScope.allCases.firstIndex(of: scope)! + 2, at: 60, kind: .screenshot, reason: scope.rawValue)
                if let data = MeetingScreenshot.jpeg(shot.image) {
                    let url = try MeetingScreenshot.write(data, to: out, relative: n)
                    err("live \(scope.rawValue): \(shot.image.width)×\(shot.image.height) px → \(url.lastPathComponent), \(data.count) bytes"
                        + (shot.note.isEmpty ? "" : " (\(shot.note))"))
                    if scope == .region, abs(Double(shot.image.width) / Double(shot.image.height) - 1.6) > 0.05 {
                        err("live region: aspect is not the region's 640×400"); failures += 1
                    }
                } else { failures += 1 }
            } catch { err("live \(scope.rawValue) failed: \(error)"); failures += 1 }
        }
        let recorder = MeetingClipRecorder()
        let clip = out.appendingPathComponent(CaptureFile.name(index: 1, at: 90, kind: .recording, reason: "smoke"))
        do {
            try await recorder.start(to: clip, scope: .display, region: nil, preferredApps: [])
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let seconds = await recorder.stop()
            let size = (try? FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int) ?? 0
            err("live clip: \(seconds.map { String(format: "%.1f s", $0) } ?? "nothing") → \(clip.lastPathComponent), \(size) bytes"
                + (recorder.failure.map { " (\($0))" } ?? ""))
            if seconds == nil || size < 1000 { failures += 1 }
        } catch { err("live clip failed: \(error)"); failures += 1 }
        print("live \(failures == 0 ? "ok" : "FAILED")")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Choosing an area

/// A dark sheet over the screen under the mouse; drag a rectangle, release
/// to keep it, Esc to give up. Returns the rectangle in global top-left
/// points — the coordinate space `CaptureRegion` stores.
@MainActor
/// A borderless panel that can still become key, so Esc reaches the view.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RegionPicker {
    private var panel: NSPanel?
    private var done: ((CaptureRegion?) -> Void)?

    func pick(_ completion: @escaping (CaptureRegion?) -> Void) {
        guard panel == nil else { completion(nil); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        // A key-capable panel: a plain borderless NSPanel can never become
        // key, so PickView's keyDown never fires and the documented
        // Esc-to-cancel is dead — the same reason NotchIsland and MoeConfirm
        // subclass. `.nonactivatingPanel` keeps it from stealing the app's
        // activation while still taking key events for Esc.
        let p = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = PickView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in
            guard let self else { return }
            let result: CaptureRegion? = rect.map { r in
                // View → screen (AppKit, bottom-left) → global CG (top-left).
                let inScreen = NSRect(x: screen.frame.minX + r.minX, y: screen.frame.minY + r.minY,
                                      width: r.width, height: r.height)
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                return CaptureRegion(x: inScreen.minX, y: primaryHeight - inScreen.maxY,
                                     width: inScreen.width, height: inScreen.height)
            }
            self.panel?.orderOut(nil)
            self.panel = nil
            let cb = self.done; self.done = nil
            cb?(result?.isUsable == true ? result : nil)
        }
        p.contentView = view
        panel = p
        done = completion
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }

    private final class PickView: NSView {
        var onFinish: ((NSRect?) -> Void)?
        private var start: NSPoint?
        private var current: NSPoint?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            if let r = selection {
                NSColor.clear.setFill()
                r.fill(using: .copy)
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
                let label = "\(Int(r.width)) × \(Int(r.height))"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let size = label.size(withAttributes: attrs)
                let box = NSRect(x: r.minX, y: max(r.minY - size.height - 8, 4), width: size.width + 10, height: size.height + 4)
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                label.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attrs)
            } else {
                let hint = "Drag to choose the area Moe captures · Esc to cancel"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let size = hint.size(withAttributes: attrs)
                let box = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 90,
                                 width: size.width + 28, height: size.height + 14)
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                hint.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attrs)
            }
        }

        private var selection: NSRect? {
            guard let a = start, let b = current else { return nil }
            return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            current = start
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            let r = selection
            finish(r)
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }
        }
        private func finish(_ r: NSRect?) {
            NSCursor.pop()
            let cb = onFinish; onFinish = nil
            cb?(r)
        }
    }
}
