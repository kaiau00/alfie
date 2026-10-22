import Foundation
import Testing

/// `TtsCatalogue.kokoroVoices` lists what Settings offers; a `.bin` beside the
/// model is what the engine can load. If they disagree, the person picks a
/// voice that fails to load — and a Kokoro pack that fails to load is not a
/// degraded voice, it is no voice.
///
/// FluidAudio publishes exactly one pack and says "single per variant". Moe
/// ships 28 because `af_heart.bin` is exactly 510 × 256 × 4 — the raw tensor —
/// so upstream's packs drop in unchanged. That makes the catalogue and the
/// converter script two lists of the same thing, written in two languages, and
/// this is what keeps them equal.
struct KokoroVoiceCatalogueTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The ids in `TtsCatalogue.kokoroVoices`.
    private static func catalogueVoices(_ source: String) -> [String] {
        guard let block = source.range(of: "static let kokoroVoices"),
              let close = source.range(of: "\n    ]", range: block.upperBound..<source.endIndex)
        else { return [] }
        return source[block.upperBound..<close.lowerBound]
            .split(separator: "\n")
            .compactMap { line in
                guard let a = line.range(of: "id: \""),
                      let b = line.range(of: "\"", range: a.upperBound..<line.endIndex)
                else { return nil }
                return String(line[a.upperBound..<b.lowerBound])
            }
    }

    /// The ids in `scripts/fetch-kokoro-voices.sh`'s VOICES list.
    private static func scriptVoices(_ script: String) -> [String] {
        guard let a = script.range(of: "VOICES=\""),
              let b = script.range(of: "\"", range: a.upperBound..<script.endIndex)
        else { return [] }
        return script[a.upperBound..<b.lowerBound]
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    @Test func theCatalogueAndTheConverterListTheSameVoices() throws {
        let swift = try #require(Self.read("Sources/Moe/TtsBackends.swift"))
        let script = try #require(Self.read("scripts/fetch-kokoro-voices.sh"))

        let offered = Set(Self.catalogueVoices(swift))
        let converted = Set(Self.scriptVoices(script))
        #expect(!offered.isEmpty, "found no voices in TtsCatalogue.kokoroVoices")
        #expect(!converted.isEmpty, "found no VOICES list in fetch-kokoro-voices.sh")

        #expect(offered.subtracting(converted).isEmpty, """
            Settings offers \(offered.subtracting(converted).sorted()) but \
            fetch-kokoro-voices.sh does not convert them, so the pack will not \
            be in the app and choosing that voice fails to load.
            """)
        #expect(converted.subtracting(offered).isEmpty, """
            fetch-kokoro-voices.sh converts \(converted.subtracting(offered).sorted()) \
            but Settings does not offer them — 522 KB each of weight nobody can pick.
            """)
    }

    /// The default has to be one of the voices, which is not automatic once
    /// the list is 28 long and edited by hand.
    @Test func theDefaultVoiceIsOneOfThem() throws {
        let swift = try #require(Self.read("Sources/Moe/TtsBackends.swift"))
        let offered = Self.catalogueVoices(swift)
        #expect(offered.contains("af_heart"),
                "af_heart is TtsCatalogue.defaultVoice(for: .kokoro) and must be listed")
        #expect(offered.first == "af_heart",
                "the default should lead the list — it is what Settings shows first")
    }

    /// Every id has to be a real Kokoro pack name, because a typo becomes a
    /// download of something that does not exist and then a voice that will
    /// not load.
    @Test func everyVoiceIdLooksLikeAKokoroPack() throws {
        let swift = try #require(Self.read("Sources/Moe/TtsBackends.swift"))
        for id in Self.catalogueVoices(swift) {
            let prefix = String(id.prefix(3))
            #expect(["af_", "am_", "bf_", "bm_"].contains(prefix), """
                "\(id)" is not an English Kokoro pack. Alfie loads only the \
                English variant, so a pack from another language cannot be \
                selected even if it converts.
                """)
        }
    }
}
