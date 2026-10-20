import Foundation
import Testing
@testable import Moe

/// The Jobs card's question and answer (review of slice B, round 3): a job
/// made before jobs recorded who asked for them, that messages somebody, is
/// asked about once — "This job messages Dan — keep?" — and Keep records the
/// person's own words for it through `reminders.py keep`.
@Suite struct RemindersKeepTests {
    @Test("a job that needs asking carries the question, and Keep says who it may message")
    func keepDecodes() throws {
        let json = """
        {"id": "j1", "name": "morning", "keep": {"asks_for": ["Dan", "Ruth"], "question": "This job messages Dan, Ruth — keep?"}}
        """
        let job = try JSONDecoder().decode(Reminders.Job.self, from: Data(json.utf8))
        let keep = try #require(job.keep)
        #expect(keep.question == "This job messages Dan, Ruth — keep?")
        #expect(keep.answer == "Keep messaging Dan, Ruth")
    }

    @Test("a job with nothing to ask carries no card")
    func noKeep() throws {
        let job = try JSONDecoder().decode(Reminders.Job.self, from: Data(#"{"id": "j2", "keep": null}"#.utf8))
        #expect(job.keep == nil)
        let bare = try JSONDecoder().decode(Reminders.Job.self, from: Data(#"{"id": "j3"}"#.utf8))
        #expect(bare.keep == nil)
    }
}
