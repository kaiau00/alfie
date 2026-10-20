import Foundation
import Testing
@testable import Moe

/// The two offer switches are real settings: the app writes only the fields
/// Config knows, so a key it did not know would be wiped by the next save of
/// any other setting (Config.save encodes Config, not the file it read).
struct OfferSettingsTests {
    @Test("off by default, and a save keeps them under the names the engine reads")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("config.json")
        var c = Config()
        #expect(c.situationOffers == false && c.situationOffersToChats == false)
        c.situationOffers = true
        c.save(to: url)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        // hermes-jobs/moe-situations.py offers_on and moe-screen deliver.py
        // OFFERS_TO_CHATS_KEY read exactly these.
        #expect(obj["situationOffers"] as? Bool == true)
        #expect(obj["situationOffersToChats"] as? Bool == false)
        let back = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        #expect(back.situationOffers == true)
    }
}
