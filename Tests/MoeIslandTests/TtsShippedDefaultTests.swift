import Foundation
import Testing

/// The voice a fresh install speaks with has to be in the app.
///
/// It was not. `Config.ttsEngine` defaulted to `"pocket"` and
/// `VoiceEngine.loadVoiceBackend` fell back to `.pocket`, while
/// `scripts/fetch-models.sh` staged `kokoro-82m-coreml kokoro` and no other
/// voice — so on a Mac that had never run Moe, the first spoken word meant
/// downloading PocketTTS (~770 MB) mid-sentence, and on a Mac with no network
/// it meant nothing at all. Neither half was wrong by itself, which is why it
/// shipped: the default was a sensible default and the staged set was a
/// sensible set, and nothing in the build or the tests compared them.
///
/// These checks compare them. Like `ConductorWiringTests`, they read the
/// sources as text — `Moe` is an executable target and Swift cannot import
/// one into a test — and they live in this target for the same reason: it is
/// the one that already reaches into `Sources/Moe`.
///
/// **If one of these fails, the fix is one of two things and never a change
/// here:** stage the default engine's model in `scripts/fetch-models.sh`, or
/// point `TtsEngineKind.shipped` at an engine that is already staged.
struct TtsShippedDefaultTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/MoeIslandTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private static func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The Hugging Face model directories each engine needs on disk, by the
    /// names `fetch-models.sh` stages them under.
    private static let modelsNeeded: [String: [String]] = [
        "kokoro":     ["kokoro-82m-coreml", "kokoro"],
    ]

    // MARK: - The invariant

    @Test func theDefaultEnginesModelIsStagedIntoTheApp() throws {
        let backends = try #require(Self.read("Sources/Moe/TtsBackends.swift"),
                                    "cannot read Sources/Moe/TtsBackends.swift")
        let fetch = try #require(Self.read("scripts/fetch-models.sh"),
                                 "cannot read scripts/fetch-models.sh")

        let engine = try #require(Self.shippedEngine(in: backends),
                                  "could not find `static let shipped: TtsEngineKind = .<engine>` in TtsBackends.swift")
        let needed = try #require(Self.modelsNeeded[engine],
                                  "TtsEngineKind.shipped is .\(engine), which this test has no model list for — add it to `modelsNeeded`")

        let staged = Self.stagedModels(in: fetch)
        #expect(!staged.isEmpty, "found no staged model names in scripts/fetch-models.sh")

        for model in needed {
            #expect(staged.contains(model), """
                The default voice is not in the app. `TtsEngineKind.shipped` is \
                .\(engine), which needs the model "\(model)", but \
                scripts/fetch-models.sh stages only: \(staged.sorted().joined(separator: " ")).

                A fresh install's first spoken word would download it mid-sentence, \
                or say nothing at all offline. Fix it one of two ways — add \
                "\(model)" to the staged set in scripts/fetch-models.sh, or point \
                TtsEngineKind.shipped at an engine whose model is already staged. \
                Do not change this test.
                """)
        }
    }

    // MARK: - …and that nothing routes around it

    @Test func configTakesItsDefaultFromThatOneConstant() throws {
        let config = try #require(Self.read("Sources/Moe/Config.swift"))
        // A literal here is how the two drifted apart the first time.
        #expect(config.contains("var ttsEngine: String = TtsEngineKind.shipped.rawValue"), """
            Config.ttsEngine must default to TtsEngineKind.shipped.rawValue rather \
            than to a string literal — a literal is what let the default and the \
            staged model set disagree with each other in a shipped build.
            """)
    }

    @Test func theEngineFallsBackToThatOneConstantToo() throws {
        let engine = try #require(Self.read("Sources/Moe/Voice/VoiceEngine.swift"))
        // `?? .pocket` was the second half of the same bug: a config naming an
        // engine this build does not know fell back past the staged one.
        for literal in ["?? .pocket", "?? .kokoro", "?? .supertonic", "?? .apple"] {
            #expect(!engine.contains(literal), """
                VoiceEngine falls back with `\(literal)`. The fallback must be \
                TtsEngineKind.shipped, or an unknown engine name in config.json \
                lands on a voice that may not be in the app.
                """)
        }
    }

    /// build.sh's own guard has to read the same constant this test does.
    ///
    /// It did not. It looked for the literal `var ttsEngine: String = "kokoro"`
    /// in Config.swift — which `configTakesItsDefaultFromThatOneConstant`
    /// above *forbids* — so `want` came back empty, `need` came back empty,
    /// and the `[ -n "$need" ]` test skipped the refusal entirely. Two tests
    /// and a shell guard, each correct on its own, adding up to a gate that
    /// reported success while seeing nothing. That is the third gate in this
    /// repo to fail by reading a field that was not there.
    @Test func theBuildScriptReadsTheSameConstantThisTestDoes() throws {
        let build = try #require(Self.read("build.sh"), "cannot read build.sh")

        #expect(build.contains("static let shipped: TtsEngineKind"), """
            build.sh must read the default voice from TtsEngineKind.shipped in             Sources/Moe/TtsBackends.swift. Any other source can disagree with             it, and a guard that disagrees with the thing it guards is worse             than no guard.
            """)
        #expect(build.contains("Sources/Moe/TtsBackends.swift"),
                "build.sh must name the file TtsEngineKind.shipped lives in")
        // The old, blind form.
        #expect(!build.contains("var ttsEngine: String = \\\""), """
            build.sh is matching a string literal in Config.swift's ttsEngine             declaration. That declaration is `TtsEngineKind.shipped.rawValue`             and the match silently yields nothing, which disables the guard.
            """)
    }

    /// Every engine the app can default to must have a model mapping in
    /// build.sh, or the guard cannot check it.
    @Test func buildScriptMapsEveryEngineToAModel() throws {
        let build = try #require(Self.read("build.sh"))
        for engine in Self.modelsNeeded.keys {
            #expect(build.contains("\(engine))"), """
                build.sh has no case for '\(engine)'. If TtsEngineKind.shipped                 is ever set to it, the guard cannot tell what to look for.
                """)
        }
    }

    // MARK: - Reading the two files

    /// `static let shipped: TtsEngineKind = .kokoro` → `"kokoro"`.
    private static func shippedEngine(in source: String) -> String? {
        guard let line = source
            .split(separator: "\n")
            .first(where: { $0.contains("static let shipped") && $0.contains("TtsEngineKind") }),
              let dot = line.range(of: "= .", options: .backwards)
        else { return nil }
        let tail = line[dot.upperBound...]
        let name = tail.prefix { $0.isLetter }
        return name.isEmpty ? nil : String(name)
    }

    /// Every model named on `fetch-models.sh`'s staging lists, whichever
    /// cache root they go to — the script keeps two, and which one a model
    /// lands in is FluidAudio's business, not this test's.
    private static func stagedModels(in script: String) -> Set<String> {
        var found: Set<String> = []
        for line in script.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"),
                  let eq = t.firstIndex(of: "="),
                  t[..<eq].hasSuffix("MODELS"),
                  let open = t.firstIndex(of: "\""),
                  let close = t.lastIndex(of: "\""), open < close
            else { continue }
            found.formUnion(t[t.index(after: open)..<close]
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty })
        }
        return found
    }
}
