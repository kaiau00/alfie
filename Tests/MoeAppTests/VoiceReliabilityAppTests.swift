import Foundation
import Testing
import MoeVoice
@testable import Moe

/// The app half of the voice reliability fixes of 2026-10-15: what the log
/// is told about a socket failure, and how PocketTTS is kept from going
/// cold under a reply.
struct VoiceReliabilityAppTests {

    /// moe.log held 35 lines like this from 09-23 to 10-02, each with a live
    /// token and a sentence of Moe's reply (stand-ins here).
    @Test func theFallbackLineCarriesNoTokenAndNoReply() {
        let failing = "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&token=SECRETTOKEN123&encoding=pcm_s16le&agent_context=Let%20me%20check%20if%20there%27s%20even%20a%20direct%20flight"
        let error = NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: [
            NSLocalizedDescriptionKey: "Socket is not connected",
            NSURLErrorFailingURLStringErrorKey: failing,
        ])
        let why = AssemblyAIBackend.reason(for: error)
        #expect(why.contains("57"))
        #expect(!why.contains("SECRETTOKEN123"))
        #expect(!why.contains("direct%20flight"))
        #expect(!why.contains("agent_context"))
    }

    // MARK: PocketTTS after an idle

    @Test func pocketGoesColdAfterAMinuteIdle() {
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(!PocketBackend.isCold(lastUsed: t, now: t.addingTimeInterval(30)))
        #expect(PocketBackend.isCold(lastUsed: t, now: t.addingTimeInterval(61)))
        // Never rendered: the load's own warm-up covers it.
        #expect(!PocketBackend.isCold(lastUsed: nil, now: t))
    }

    /// A 2.9× reading taken before a two-minute pause is the warm engine; it
    /// does not size the first sentence after the pause.
    @Test func aStaleFastSpeedIsNotTrusted() {
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(SpeechOut.speedForHeadStart(measured: 2.9, measuredAt: t, now: t.addingTimeInterval(20)) == 2.9)
        #expect(SpeechOut.speedForHeadStart(measured: 2.9, measuredAt: t, now: t.addingTimeInterval(120)) == nil)
        // A stale slow reading is still a warning.
        #expect(SpeechOut.speedForHeadStart(measured: 0.9, measuredAt: t, now: t.addingTimeInterval(120)) == 0.9)
    }

    /// Half a second in hand before the first word (was 0.25 s): 17 replies
    /// ran dry mid-word from 10-02 to 10-15.
    @Test func theHeadStartFloorIsHalfASecond() {
        #expect(SpeechOut.preRollSeconds == 0.5)
        #expect(SpeechOut.headStart(floor: SpeechOut.preRollSeconds, speechSeconds: 4, speed: nil) == 0.5)
    }
}
