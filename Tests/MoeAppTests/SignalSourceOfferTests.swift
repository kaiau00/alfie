import Foundation
import Testing
@testable import Moe

/// The in-app licence screen must carry the Signal source offer, and say
/// exactly what NOTICE says. Owner decision 2026-09-14: offer the source,
/// ship it. `Licenses.notice` is a string constant duplicated from NOTICE on
/// purpose (see its doc comment), which is exactly how the two drifted: the
/// components were listed on the screen and the offer they pointed at was
/// only in the file nobody sees. scripts/test-legal-pages.sh holds the
/// website's copy to NOTICE the same way.
struct SignalSourceOfferTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The paragraph beginning `prefix`, whitespace collapsed — a Swift line
    /// continuation and a hard-wrapped text file differ only there.
    static func paragraph(startingWith prefix: String, in text: String) -> String? {
        text.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { $0.hasPrefix(prefix) }
    }

    @Test func theAppShowsWhereTheSignalSourceIs() {
        let shown = Self.paragraph(startingWith: "Signal —", in: Licenses.notice)
        #expect(shown != nil, "Licenses.notice has no Signal paragraph")
        // Each component's source at its exact tag, not a repository root with
        // the tag in prose. That the tags are the versions fetch-signal-cli.sh
        // pins is scripts/test-legal-pages.sh §3c.
        for needed in ["https://github.com/AsamK/signal-cli/tree/v0.14.8",
                       "https://github.com/signalapp/libsignal/tree/v0.102.1",
                       "https://github.com/adoptium/jdk25u/tree/jdk-25.0.4.1+1_adopt",
                       "complete corresponding source", "three years"] {
            #expect(shown?.contains(needed) == true, "the in-app Signal notice lacks \(needed)")
        }
    }

    @Test func theAppAndNOTICESayTheSameThing() throws {
        let file = try String(contentsOf: Self.repo.appendingPathComponent("NOTICE"), encoding: .utf8)
        let inFile = Self.paragraph(startingWith: "Signal —", in: file)
        #expect(inFile != nil, "NOTICE has no Signal paragraph")
        #expect(inFile == Self.paragraph(startingWith: "Signal —", in: Licenses.notice))
    }
}
