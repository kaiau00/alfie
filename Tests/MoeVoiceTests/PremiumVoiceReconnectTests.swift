import Foundation
import Testing
@testable import MoeVoice

/// What the person is told when the premium voice's connection drops for a
/// moment (2026-09-24 19:50, a ten-second blip that left the voice local for
/// a minute and unexplained): one quiet line per stretch, nothing when it
/// comes back, and the out-of-credits rule left exactly as it was.
struct PremiumVoiceReconnectTests {

    private let t0 = Date(timeIntervalSince1970: 1_758_740_000)

    private struct EdgeOffline: PremiumVoiceConnectionFailure {
        var isConnectionDrop: Bool { true }
    }
    private struct NotEntitled: PremiumVoiceConnectionFailure {
        var isConnectionDrop: Bool { false }
    }

    @Test("a dropped connection: exactly one notice for the whole stretch, however many sentences")
    func oneNoticePerEpisode() {
        var r = PremiumVoiceReconnect()
        var notices: [String] = []
        for i in 0..<12 {
            let error: Error = i == 0 ? EdgeOffline() : InworldError.unreachable("in backoff")
            if case .connection(let notice) = r.failed(error, now: t0.addingTimeInterval(Double(i))),
               let notice { notices.append(notice) }
        }
        #expect(notices == [PremiumVoiceReconnect.notice])
        #expect(r.sentencesLocal == 12)
        #expect(r.inEpisode)
    }

    @Test("the voice coming back ends the stretch silently, and the next drop is news again")
    func recoveryIsLoggedNotAnnouncedAndRearms() {
        var r = PremiumVoiceReconnect()
        #expect(r.succeeded(now: t0) == nil, "nothing to recover from")
        _ = r.failed(URLError(.notConnectedToInternet), now: t0)
        _ = r.failed(EdgeOffline(), now: t0.addingTimeInterval(3))
        let away = r.succeeded(now: t0.addingTimeInterval(14))
        #expect(away == 14)
        #expect(!r.inEpisode)
        #expect(r.succeeded(now: t0.addingTimeInterval(15)) == nil, "said once")
        #expect(r.failed(EdgeOffline(), now: t0.addingTimeInterval(900))
                == .connection(notice: PremiumVoiceReconnect.notice),
                "a later blip is a new stretch with its own notice")
    }

    @Test("out of credits is not a dropped connection: its own rule, no episode, no second notice")
    func outOfCreditsIsUnaffected() {
        var r = PremiumVoiceReconnect()
        let refusal = InworldError.rejected("You have no credits remaining. Please add credits to continue using the service.")
        #expect(PremiumVoiceSpent.matches(refusal))
        #expect(r.failed(refusal, now: t0) == .outOfCredits)
        #expect(!r.inEpisode)
        #expect(r.sentencesLocal == 0)
        #expect(!PremiumVoiceReconnect.isConnectionDrop(refusal))
        // And a drop during a spent stretch is still its own thing.
        #expect(r.failed(EdgeOffline(), now: t0) == .connection(notice: PremiumVoiceReconnect.notice))
    }

    @Test("an auth or request failure keeps its old handling: local for the sentence, nothing said")
    func otherFailuresSayNothing() {
        var r = PremiumVoiceReconnect()
        #expect(r.failed(InworldError.rejected("Unknown voice id"), now: t0) == .other)
        #expect(r.failed(NotEntitled(), now: t0) == .other)
        #expect(r.failed(CancellationError(), now: t0) == .other)
        #expect(!r.inEpisode)
    }

    @Test("what counts as the connection: the edge not answering, the socket failing or dying, the URL stack")
    func classification() {
        #expect(PremiumVoiceReconnect.isConnectionDrop(EdgeOffline()))
        #expect(PremiumVoiceReconnect.isConnectionDrop(InworldError.unreachable("x")))
        #expect(PremiumVoiceReconnect.isConnectionDrop(InworldError.connectionLost("Socket is not connected")))
        #expect(PremiumVoiceReconnect.isConnectionDrop(URLError(.cannotConnectToHost)))
        #expect(PremiumVoiceReconnect.isConnectionDrop(NSError(domain: NSPOSIXErrorDomain, code: 57)))
        #expect(!PremiumVoiceReconnect.isConnectionDrop(NotEntitled()))
        #expect(!PremiumVoiceReconnect.isConnectionDrop(InworldError.rejected("bad request")))
    }

    @Test("a voice reloaded mid-stretch starts clean")
    func resetForgets() {
        var r = PremiumVoiceReconnect()
        _ = r.failed(EdgeOffline(), now: t0)
        r.reset()
        #expect(!r.inEpisode)
        #expect(r.succeeded(now: t0) == nil)
    }
}
