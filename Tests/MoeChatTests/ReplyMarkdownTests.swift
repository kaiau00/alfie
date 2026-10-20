import Foundation
import Testing
@testable import MoeChat

/// The notch showed `**bold**` with its asterisks on (2026-09-20) because the
/// island parsed markdown only when a reply held a link. Both surfaces read
/// from here now.
@Suite struct ReplyMarkdownTests {

    @Test func boldLosesItsAsterisksAndKeepsItsWeight() {
        let out = ReplyMarkdown.inline("- **Tomorrow is Yom Kippur** — nothing else on your calendar.")
        let plain = String(out.characters)
        #expect(!plain.contains("**"))
        #expect(plain.hasPrefix("- Tomorrow is Yom Kippur — nothing"))
        let bold = out.runs.first { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(String(out[bold!.range].characters) == "Tomorrow is Yom Kippur")
    }

    @Test func lineBreaksSurviveSoAListStaysAList() {
        let out = ReplyMarkdown.inline("Quick lay of the land:\n\n- one\n- two")
        #expect(String(out.characters) == "Quick lay of the land:\n\n- one\n- two")
    }

    @Test func aBareAddressBecomesALink() {
        let out = ReplyMarkdown.inline("see https://example.com/page today")
        let link = out.runs.first { $0.link != nil }
        #expect(link?.link?.absoluteString == "https://example.com/page")
        #expect(!String(out.characters).contains("]("))
    }

    @Test func plainProseIsUntouched() {
        #expect(String(ReplyMarkdown.inline("Good morning.").characters) == "Good morning.")
    }
}
