import AppKit
import ApplicationServices
import Foundation
import MoeDictation

/// Watches what the user does to a dictation right after it is pasted, and
/// hands the result to `CorrectionLearner`.
///
/// A few seconds after the paste, if the same app is still in front and
/// Accessibility can read the focused element's value, the tail of that
/// value is diffed against what was pasted. "Shavon" typed over as
/// "Siobhan" becomes a `shavon => Siobhan` line in
/// `~/.moe/vocabulary-learned.txt` — once it has been seen twice, with the
/// first sighting kept in `~/.moe/vocabulary-pending.json`.
///
/// Nothing here is logged but counts. The text read back is the user's own
/// field, and it is dropped as soon as the diff is done. Needs only the
/// Accessibility permission the paste itself already needs, which is why the
/// setting defaults to on.
enum CorrectionWatcher {

    /// Long enough to notice and fix a name; short enough that the field
    /// is usually still there.
    static let delay: TimeInterval = 8

    /// The most of the field's value that is looked at. A whole document
    /// can be behind a text view; only the end can hold the paste.
    private static let readLimit = 20_000

    static var pendingURL: URL { Config.homeDir.appendingPathComponent("vocabulary-pending.json") }
    static var learnedURL: URL { Config.homeDir.appendingPathComponent(Vocabulary.learnedFile) }

    @MainActor private static var task: Task<Void, Never>?

    /// Call right after a successful paste. A second dictation before the
    /// delay is up replaces the watch — the field has changed under it.
    @MainActor
    static func watch(pasted: String, frontApp bundleID: String?) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            guard let observed = focusedValue() else { return }
            learn(pasted: pasted, observed: observed)
        }
    }

    /// The tail of the focused element's value as text, or nil when there
    /// is none, the app does not expose one (a web view often doesn't), or
    /// focus has moved to a password field.
    ///
    /// A long document is read by range where the app supports it
    /// (`kAXStringForRangeParameterizedAttribute`), so a whole 2 MB text
    /// view is not copied over to look at its last few lines; failing that,
    /// the value is read whole and cut down here.
    @MainActor
    private static func focusedValue() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           role as? String == "AXSecureTextField" {
            return nil
        }

        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let n = count as? Int, n > readLimit {
            var range = CFRange(location: n - readLimit, length: readLimit)
            if let param = AXValueCreate(.cfRange, &range) {
                var tail: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, param, &tail) == .success,
                   let text = tail as? String, !text.isEmpty {
                    return text
                }
            }
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                            &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text.utf16.count > readLimit ? String(text.suffix(readLimit)) : text
    }

    /// Off the main thread: the diff is small but the files are not ours to
    /// block the UI on.
    private static func learn(pasted: String, observed: String) {
        DispatchQueue.global(qos: .utility).async {
            let found = CorrectionLearner.corrections(pasted: pasted, observed: observed,
                                                      common: .system)
            guard !found.isEmpty else { return }

            let known = Set(Vocabulary.shared.entries.keys)
            var pending = CorrectionLearner.Pending(data: (try? Data(contentsOf: pendingURL)) ?? Data())
            let promoted = pending.record(found, known: known)
            writePrivately(pending.data(), to: pendingURL)

            guard !promoted.isEmpty else {
                Log.write("dictation: \(found.count) correction(s) noted, waiting for a second sighting")
                return
            }
            var lines = ""
            if !FileManager.default.fileExists(atPath: learnedURL.path) {
                lines += """
                # Spellings Moe learned from your corrections (heard => what you typed).
                # Edit or delete lines freely; vocabulary.txt wins over this file.

                """
            }
            lines += promoted.map(\.line).joined(separator: "\n") + "\n"
            append(lines, to: learnedURL)
            Log.write("dictation: learned \(promoted.count) spelling(s)")
        }
    }

    private static func writePrivately(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: Config.homeDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.write("dictation: could not write \(url.lastPathComponent) (\(error.localizedDescription))")
        }
    }

    private static func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            writePrivately(data, to: url)
        }
    }
}
