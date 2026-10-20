import Foundation
import Testing
@testable import MoeVoice

/// `URLSessionWebSocketTask.sendPing` calls its handler twice when the socket
/// aborts, and a continuation resumed twice quit the app mid-reply
/// (2026-09-29 20:02, 2026-09-30 16:52). These fakes do exactly that.
/// Without the one-shot, the first two tests die with "tried to resume its
/// continuation more than once" rather than failing.
@Suite struct OneShotCompletionTests {

    struct Abort: Error {}

    @Test func anErrorThenASecondCallThrowsTheFirstAndSurvives() async {
        var thrown: Error?
        do {
            try await OneShot.completion { done in
                done(Abort())
                done(URLError(.cancelled))
            }
        } catch {
            thrown = error
        }
        #expect(thrown is Abort)
    }

    @Test func successThenAnErrorIsASuccess() async throws {
        try await OneShot.completion { done in
            done(nil)
            done(Abort())
        }
    }

    @Test func aSecondCallFromAnotherThreadIsDropped() async {
        var thrown: Error?
        do {
            try await OneShot.completion { done in
                DispatchQueue.global().async { done(Abort()) }
                DispatchQueue.global().async { done(Abort()) }
            }
        } catch {
            thrown = error
        }
        #expect(thrown is Abort)
    }

    @Test func claimIsOnlyOnce() {
        let once = OneShot()
        #expect(once.claim())
        #expect(!once.claim())
    }
}
