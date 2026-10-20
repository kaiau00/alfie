import AppKit
import Foundation
import MoeDictation

/// `Moe --context-terms [seconds]` — what the screen harvest would give this
/// dictation, printed instead of used.
///
/// The screen vocabulary is the kind of feature that is invisible when it
/// works and indistinguishable from a bad recogniser when it does not: a name
/// comes out right and nobody notices, or a word comes out wrong and the
/// engine gets the blame. The same argument that put a `--stt-test` behind
/// `VocabularyBoost` puts this here.
///
/// It counts down, so you can bring the window you care about to the front,
/// then reports what `ScreenText` found and what survived `ContextTerms` —
/// with the timing, because the harvest sits on the keypress and a walk that
/// takes 80 ms is a bug however good its output is.
enum ContextTermsSelfTest {

    @MainActor
    static func run(after seconds: Int = 5) async -> Int32 {
        guard AXIsProcessTrusted() else {
            print("Accessibility is not granted — the harvest reads nothing.")
            print("System Settings › Privacy & Security › Accessibility.")
            return 1
        }

        if seconds > 0 {
            print("Bring the window you want to test to the front…")
            for remaining in stride(from: seconds, through: 1, by: -1) {
                print("  \(remaining)…")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // The app warms this at launch (see `Conductor.init`), so timing it
        // cold here would measure a stall the real path never pays.
        let dictionaryStart = Date()
        _ = CommonWords.system
        let dictionaryMs = Date().timeIntervalSince(dictionaryStart) * 1000

        let app = NSWorkspace.shared.frontmostApplication
        print("\nFront app: \(app?.localizedName ?? "unknown") "
            + "(\(app?.bundleIdentifier ?? "—"))")

        let t0 = Date()
        let sources = ScreenText.sources()
        let readMs = Date().timeIntervalSince(t0) * 1000

        let t1 = Date()
        let terms = ContextTerms.extract(sources, common: .system)
        let filterMs = Date().timeIntervalSince(t1) * 1000

        let chars = sources.reduce(0) { $0 + $1.count }
        print(String(format: "Read:   %d source(s), %d chars in %.1f ms%@",
                     sources.count, chars, readMs,
                     readMs > ScreenText.budget * 1000 ? "  ← over budget" : ""))
        print(String(format: "Filter: %d term(s) in %.1f ms", terms.count, filterMs))
        print(String(format: "        (system dictionary loaded in %.1f ms — warmed at launch, "
                           + "not paid on a keypress)", dictionaryMs))

        if terms.isEmpty {
            print("\nNothing worth boosting here — which is the right answer for a "
                + "window with no names in it.")
        } else {
            print("\nTerms, most relevant first:")
            for row in stride(from: 0, to: terms.count, by: 6) {
                print("  " + terms[row..<min(row + 6, terms.count)].joined(separator: "  "))
            }
        }
        print("\nNone of this was stored. It is what one dictation would have "
            + "carried, and it would be gone by now.")
        return 0
    }
}
