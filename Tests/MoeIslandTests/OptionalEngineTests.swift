import Foundation
import Testing

/// The two promises an optional voice engine makes, held against the files
/// rather than against intent.
///
/// PocketTTS is offered in Settings and downloads on request — 939 MB,
/// measured, into FluidAudio's own cache. Two things must stay true for
/// that to be safe, and neither is enforced by anything a person reads:
///
/// 1. **It is never in the app.** Not in `Models.bundled`, not in
///    `fetch-models.sh`'s lists. `scripts/check-bundled-models.sh` then
///    refuses any build that carries it, because its "extra" arm rejects a
///    staged directory the lists do not name. That guard already exists;
///    this proves it still applies to this engine.
/// 2. **It can never become the shipped default.** `build.sh` maps the
///    shipped engine to the model that must be inside the bundle, and its
///    `*)` arm refuses an engine it has no mapping for. So the protection
///    is the *absence* of a `pocket)` case — which is exactly the kind of
///    thing a later commit adds in passing to "fix the build", shipping an
///    app whose first spoken word is a 939 MB download.
///
/// Both are read out of the real files. A test that restated the rule in
/// Swift would agree with itself and nothing else.
struct OptionalEngineTests {

    private static let root: URL = {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir = dir.deletingLastPathComponent() }
        return dir
    }()

    private func read(_ path: String) throws -> String {
        let url = Self.root.appendingPathComponent(path)
        guard let s = try? String(contentsOf: url, encoding: .utf8) else {
            throw AnyError("cannot read \(path) — this check cannot run, so it fails")
        }
        return s
    }

    struct AnyError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// The engine must not appear in anything that decides what is staged
    /// into `Models/`.
    @Test func pocketTtsIsInNoBundledModelList() throws {
        let fetch = try read("scripts/fetch-models.sh")
        // Only the two list assignments matter; the file talks about
        // pocket-tts elsewhere, in the comment explaining the pruning.
        for name in ["APP_SUPPORT_MODELS", "CACHE_MODELS"] {
            let line = fetch.split(separator: "\n")
                .first { $0.hasPrefix("\(name)=") }
                .map(String.init) ?? ""
            #expect(!line.contains("pocket"),
                    "\(name) names pocket-tts, which would put a 939 MB optional engine inside the app")
        }

        let models = try read("Sources/Moe/Models.swift")
        let bundled = models.components(separatedBy: "static let bundled")
            .dropFirst().first?.components(separatedBy: "]").first ?? ""
        #expect(!bundled.contains("pocket"),
                "Models.bundled names pocket-tts; linkIfNeeded would look for it in the app")
    }

    /// The absence that is load-bearing. `build.sh` refuses a shipped engine
    /// it has no model mapping for, and PocketTTS having no mapping is what
    /// stops it ever becoming the default.
    @Test func buildRefusesPocketTtsAsTheShippedDefault() throws {
        let build = try read("build.sh")

        // The catch-all must still be there…
        #expect(build.contains("TtsEngineKind.shipped is"),
                "build.sh no longer refuses an unmapped shipped engine — the guard is gone")

        // …and PocketTTS must still be unmapped. `pocket)` is the case arm
        // that would silently allow it.
        #expect(!build.contains("pocket)"),
                "build.sh gained a `pocket)` arm — that lets TtsEngineKind.shipped = .pocket ship an app whose default voice is a 939 MB download")
    }

    /// And the default is what it should be. This is the one line that
    /// decides whether a fresh Mac can speak before it can download.
    @Test func theShippedDefaultIsStillBundledKokoro() throws {
        let backends = try read("Sources/Moe/TtsBackends.swift")
        #expect(backends.contains("static let shipped: TtsEngineKind = .kokoro"),
                "the shipped default changed; check it is an engine that is actually in the bundle")
    }

    /// Every voice Settings offers for PocketTTS has to exist in the pack it
    /// downloads, or choosing it is a load failure and no voice at all —
    /// the exact bug `loadVoiceBackend` was taught to survive when a config
    /// still said `pocket` / `george` after the engine was removed.
    ///
    /// The names are checked against the downloaded pack when there is one
    /// on this machine, and skipped when there is not, rather than compared
    /// against a second hardcoded list.
    ///
    /// **The skip is a real skip now.** It used to `throw XCTSkipLike`, and
    /// swift-testing has no XCTSkip: a thrown error is a *failure*. So this
    /// suite was red on every Mac that had not downloaded the 939 MB pack —
    /// including this one after the 2026-09-07 fresh-user wipe — and a red
    /// test nobody can make green is a test everybody learns to ignore. The
    /// half that can be checked without the pack now lives in
    /// `theOfferedPocketVoicesIncludeTheDefault`, below, which never skips.
    @Test func everyOfferedPocketVoiceExistsInThePack() throws {
        let pack = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models/pocket-tts/v2.1/english/constants_bin")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: pack.path) else {
            print("skipped: PocketTTS is not downloaded on this Mac (\(pack.path))")
            return
        }
        let onDisk = Set(files.filter { $0.hasSuffix(".safetensors") }
            .map { $0.replacingOccurrences(of: ".safetensors", with: "") })
        #expect(!onDisk.isEmpty)

        let offered = try Self.offeredPocketVoices(in: read("Sources/Moe/TtsBackends.swift"))
        #expect(offered.count >= 20, "only \(offered.count) voices parsed — the catalogue shape changed")

        for id in offered {
            #expect(onDisk.contains(id),
                    "Settings offers PocketTTS voice '\(id)' but the pack has no \(id).safetensors")
        }
    }

    /// PocketTTS starts on Peter, and Peter is a voice it offers.
    ///
    /// Asked for again on 2026-09-07 — "when a user uses Pocket TTS, if
    /// they download it, the default voice over there should be Peter" —
    /// and it is checked here rather than in the test above because that
    /// one skips on a Mac without the pack, which is most of them. A
    /// default the engine does not carry is a load failure and no voice at
    /// all; a default that quietly moves is a person's setting changing
    /// under them. Neither needs 939 MB to catch.
    @Test func theOfferedPocketVoicesIncludeTheDefault() throws {
        let backends = try read("Sources/Moe/TtsBackends.swift")
        let arm = backends.components(separatedBy: "static func defaultVoice").dropFirst().first?
            .components(separatedBy: "\n    }").first ?? ""
        #expect(!arm.isEmpty, "TtsCatalogue.defaultVoice is gone")
        let pocket = arm.components(separatedBy: "case .pocket:").dropFirst().first?
            .components(separatedBy: "\n").first ?? ""
        #expect(pocket.contains("\"peter_yearsley\""),
                "PocketTTS's default voice is \(pocket.trimmingCharacters(in: .whitespaces)), not Peter")

        let offered = Self.offeredPocketVoices(in: backends)
        #expect(offered.contains("peter_yearsley"),
                "peter_yearsley is the default but Settings does not offer it")
    }

    /// The ids in `TtsCatalogue.pocketVoices`. Hand-parsed rather than with
    /// a regex literal: this target builds in Swift 5 language mode, where
    /// `/.../` is a division operator.
    private static func offeredPocketVoices(in backends: String) -> [String] {
        let block = backends.components(separatedBy: "static let pocketVoices")
            .dropFirst().first?.components(separatedBy: "].map").first ?? ""
        var offered: [String] = []
        for piece in block.components(separatedBy: "(\"").dropFirst() {
            if let id = piece.components(separatedBy: "\"").first,
               !id.isEmpty, id.allSatisfy({ $0.isLowercase || $0 == "_" }) {
                offered.append(id)
            }
        }
        return offered
    }

    /// The way a person gets the engine at all. Nothing bundles it and
    /// `loadVoiceBackend` will not fetch it (it speaks with Kokoro and says
    /// why), so the pane has to offer the download itself — and until
    /// 2026-09-07 it did not: a label said "939 MB to download, once" and
    /// nothing on the pane could start it. Two things are held here: the
    /// pane streams `PocketBackend.download()` behind a button that names
    /// the size, and "is it here" is FluidAudio's required-file list rather
    /// than "the folder is not empty", which a download stopped half-way
    /// also satisfies.
    @Test func theVoicePaneOffersTheDownloadAndChecksEveryFile() throws {
        let pane = try read("Sources/Moe/Settings/VoicePane.swift")
        #expect(pane.contains("PocketBackend.download()"),
                "the Voice pane no longer fetches PocketTTS — an engine that is not in the app must be downloadable from Settings")
        #expect(pane.contains("939 MB download, once"),
                "the Download row no longer says the size before the button is pressed — that is what a person agrees to")
        #expect(pane.contains("PaneButton(title: \"Cancel\") { cancelPocketDownload() }"),
                "the download cannot be stopped from the row")
        #expect(pane.contains("\"Download PocketTTS first.\""),
                "Use and preview no longer says why it is off while the pack is missing")

        let backends = try read("Sources/Moe/TtsBackends.swift")
        #expect(backends.contains("ModelNames.PocketTTS.requiredModels(precision: precision, placement: placement)"),
                "isDownloaded no longer checks FluidAudio's required-file list for the variant Alfie loads")
        #expect(!backends.contains("return !contents.isEmpty"),
                "isDownloaded is back to 'the folder is not empty', which a half-finished download satisfies")
    }

}
