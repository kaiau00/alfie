import AppKit
import MoeScreen
import ScreenCaptureKit

/// One screenshot, taken the instant the talk key went down, ready to ride
/// along with the words as an `image_url` data URL.
///
/// Kept in memory only: it is context for one turn, never written to disk
/// and never logged beyond its dimensions and size.
struct ScreenCapture {
    /// JPEG bytes, longest side ≤ `ScreenContext.maxSide`.
    let jpeg: Data
    let width: Int
    let height: Int
    /// The captured display's bounds in global CoreGraphics coordinates
    /// (origin top-left of the primary display, in points). With `width`
    /// and `height` this maps a screenshot pixel back to a screen point.
    let displayFrame: CGRect
    let takenAt: Date

    /// The pixel → point arithmetic, unit-tested in MoeScreen.
    var geometry: ScreenGeometry { ScreenGeometry(width: width, height: height, displayFrame: displayFrame) }

    /// Screenshot pixels per screen point.
    var scale: CGFloat { geometry.scale }

    /// A screenshot pixel → the same spot on screen, CoreGraphics
    /// coordinates (top-left origin), the ones `CGWarpMouseCursorPosition`
    /// and `SCDisplay.frame` speak.
    func screenPoint(x: Int, y: Int) -> CGPoint { geometry.screenPoint(x: x, y: y) }

    var attachment: ImageAttachment { ImageAttachment(data: jpeg, mediaType: "image/jpeg") }

    /// "1568×982 (187 KB)" — all the log ever says about it.
    var summary: String { "\(width)×\(height) (\(jpeg.count / 1024) KB)" }
}

/// Moe's eyes at the moment you speak (modelled on farzaa/clicky, MIT).
///
/// The agent key going down starts a capture of the display under the
/// cursor; the next user turn takes it — one screenshot per utterance,
/// refreshed once at release if the hold ran long, so what the model sees
/// is what you were looking at. Dictation never comes here.
///
/// Capture is ScreenCaptureKit's `SCScreenshotManager`, which runs under
/// the same Screen Recording grant (TCC `kTCCServiceScreenCapture`) that
/// Hermes's `computer_use` already needs for `screencapture`; both are
/// attributed to Memoe.app, so no new prompt. Without the grant nothing is
/// captured and the turn goes out as text — the check is a preflight, so
/// a key press never pops a system dialog.
@MainActor
final class ScreenContext {

    /// Anthropic's sweet spot: larger is downscaled by the API anyway.
    nonisolated static let maxSide = 1568
    /// Context, not pixels: q80 JPEG of a busy 1568-wide screen is ~200 KB
    /// against ~1 MB for PNG.
    nonisolated static let jpegQuality: CGFloat = 0.8
    /// A hold longer than this gets a fresh capture at release.
    nonisolated static let staleAfter: TimeInterval = 10

    /// Mirrors `Config.screenContext`; off means every call here is a no-op.
    var enabled = true

    private var pending: Task<ScreenCapture?, Never>?
    private var pressedAt: Date?
    private static var warnedNoPermission = false

    init() {}

    /// The agent key went down (or the wake word matched): capture now.
    func pressBegan() {
        guard enabled else { return }
        pressedAt = Date()
        pending = Task { await Self.capture() }
    }

    /// The key came up. A long hold means the first capture is stale.
    func pressEnded() {
        guard enabled, let at = pressedAt else { return }
        pressedAt = nil
        if Date().timeIntervalSince(at) > Self.staleAfter {
            pending = Task { await Self.capture() }
        }
    }

    /// The screenshot for this turn, if one was started. Consumed: a second
    /// call returns nil until the next press.
    func take() async -> ScreenCapture? {
        guard let task = pending else { return nil }
        pending = nil
        pressedAt = nil
        return await task.value
    }

    func discard() {
        pending?.cancel()
        pending = nil
        pressedAt = nil
    }

    // MARK: - Is this question even about the screen?

    /// Whether a spoken turn sounds like it refers to what is on screen.
    ///
    /// The picture is not free. Measured against the local gateway, the same
    /// question on the same warm session answered in 0.78 s and 2.86 s with
    /// no image and 3.37 s and 5.36 s with one: about two and a half seconds
    /// of time-to-first-token, on every hold turn, for a 1568-pixel JPEG that
    /// most questions have no use for. "How's my day looking?" was paying it.
    ///
    /// Deliberately generous. A false positive costs the 2.5 s that used to
    /// be unconditional, which is exactly the old behaviour; a false negative
    /// leaves Moe answering blind about something the user can see, which is
    /// worse and more confusing. So anything that plausibly points at the
    /// screen sends the picture, and the saving comes from the plainly
    /// unvisual majority — the day, the diary, the news, a reminder.
    ///
    /// "that" is the reason this is a word list rather than a rule about
    /// demonstratives. It is overwhelmingly non-visual in real use — "that
    /// email", "that meeting", "remind me about that" — and including it
    /// matched nearly every turn and saved nothing. "this" and "here" stay:
    /// spoken at an assistant, they usually do mean the thing in front of us.
    nonisolated static func mightBeAboutTheScreen(_ text: String) -> Bool {
        var s = " " + text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) + " "

        // "this week" is a diary question, not a screen one, and over 217 real
        // turns the temporal senses of "this" were the largest single source
        // of pictures nobody wanted — "How's my calendar this week?" was
        // paying two and a half seconds for a screenshot of nothing.
        for w in Self.temporalAfterThis {
            s = s.replacingOccurrences(of: " this \(w) ", with: " \(w) ")
        }

        // Whole words only: "this" must not match "thistle", and — the one
        // that actually bit — "here" must not match "there", which is in
        // "there's a meeting at three" and half of everything else.
        for word in wholeWordCues where s.contains(" \(word) ") { return true }
        for phrase in phraseCues where s.contains(phrase) { return true }
        return false
    }

    /// "this" followed by any of these is about time, not about the display.
    private nonisolated static let temporalAfterThis: Set<String> = [
        "week", "month", "morning", "afternoon", "evening", "year",
        "time", "weekend", "one", "many", "much", "far", "point",
    ]

    /// Nouns for things only found on a display, plus the two deictics that
    /// survive contact with real speech.
    private nonisolated static let wholeWordCues: Set<String> = [
        "screen", "screens", "display", "monitor", "window", "windows",
        "tab", "tabs", "page", "dialog", "popup", "menu", "toolbar",
        "sidebar", "cursor", "button", "buttons", "icon", "highlighted",
        "selected", "this", "here", "clicking", "typing",
    ]

    /// Multi-word cues, matched on the same flattened text, so "pop-up" and
    /// "pop up" are the same thing and punctuation never decides.
    /// No "can you see" or "look at" here. They read as screen cues and are
    /// not: "Can you see my WhatsApp?" and "look at the OpenClaw blog post"
    /// both want a connector, not a picture. The ones that really are about
    /// the display say "screen", and the noun above already catches those.
    private nonisolated static let phraseCues: [String] = [
        " what does it say ", " what is it saying ", " on my screen ",
        " in front of me ", " over there ", " right there ", " pop up ",
        " error message ", " read it ", " what do i do ", " fix it ",
    ]

    // MARK: - Capture

    nonisolated static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The display under the mouse, downscaled and JPEG-encoded. Nil when
    /// Screen Recording is not granted or the capture fails.
    static func capture() async -> ScreenCapture? {
        guard hasPermission else {
            if !warnedNoPermission {
                warnedNoPermission = true
                Log.write("screen: no Screen Recording permission — talking without a screenshot")
            }
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = displayUnderMouse(content.displays) else { return nil }
            let frame = display.frame
            let backing = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }?.backingScaleFactor ?? 2
            let (w, h) = fit(Int(frame.width * backing), Int(frame.height * backing))

            // Hide Moe's overlays (the island, the pointer ring) — they float
            // above everything and are not what the user is asking about —
            // but NOT Moe's normal windows: a screenshot that omits a window
            // the user can see makes the model click "through" it into
            // whatever is underneath. Overlays are the panels above the
            // normal window layer; the settings window sits at layer 0.
            // Only the pointer ring is excluded (screen-saver layer). The
            // island is a real panel that catches clicks when it is open, so
            // it must appear too — the model clicked into it while it was
            // hidden from the picture.
            let overlays = content.windows.filter {
                $0.owningApplication?.processID == getpid()
                    && $0.windowLayer >= Int(CGWindowLevelForKey(.screenSaverWindow))
            }
            let filter = SCContentFilter(display: display, excludingWindows: overlays)
            let cfg = SCStreamConfiguration()
            cfg.width = w
            cfg.height = h
            cfg.showsCursor = true
            cfg.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            // The JPEG encode is tens of milliseconds; keep it off the main
            // actor, which the key press and the island are on.
            return await Task.detached(priority: .userInitiated) {
                encode(image, displayFrame: frame)
            }.value
        } catch {
            Log.write("screen: capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func displayUnderMouse(_ displays: [SCDisplay]) -> SCDisplay? {
        // NSEvent.mouseLocation is bottom-left based; SCDisplay.frame is
        // top-left based. Convert through the primary screen's height.
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        return displays.first { $0.frame.contains(cg) } ?? displays.first
    }

    /// Longest side to ≤ `maxSide`, aspect kept.
    nonisolated static func fit(_ w: Int, _ h: Int) -> (Int, Int) {
        let longest = max(w, h)
        guard longest > maxSide, longest > 0 else { return (max(w, 1), max(h, 1)) }
        let f = Double(maxSide) / Double(longest)
        return (max(Int(Double(w) * f), 1), max(Int(Double(h) * f), 1))
    }

    /// Downscale (if still too big) and JPEG-encode. Shared with
    /// `Moe --screen-test`, which feeds it a synthetic image.
    nonisolated static func encode(_ image: CGImage, displayFrame: CGRect) -> ScreenCapture? {
        let (w, h) = fit(image.width, image.height)
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
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) else {
            return nil
        }
        return ScreenCapture(jpeg: jpeg, width: cg.width, height: cg.height,
                             displayFrame: displayFrame, takenAt: Date())
    }
}
