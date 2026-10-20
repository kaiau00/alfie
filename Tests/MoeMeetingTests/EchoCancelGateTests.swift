import Foundation
import Testing
@testable import MoeMeeting

// Echo cancellation must never run while a call app has the microphone:
// voice processing switches the built-in mic into its raw multi-channel
// mode for every process, and a raw input client (Telegram, Signal,
// WhatsApp — WebRTC) then reads near-silence until it is released.
// Measured 2026-09-02; see MicCapture "Not over a call".

private func sig(_ id: String, input: Bool = true, output: Bool = true) -> CallSignal {
    CallSignal(bundleID: id, input: input, output: output)
}

struct EchoCancelGateTests {

    @Test func telegramOnTheMicIsACall() {
        let calls = CallApps.onMicrophone([sig("com.tdesktop.Telegram")])
        #expect(calls.map(\.name) == ["Telegram"])
    }

    /// Siri's listener and a dictation helper hold the microphone all day
    /// on a normal Mac. They are not calls, and must not cost the meeting
    /// its echo cancellation.
    @Test func alwaysOnListenersAreNotCalls() {
        let calls = CallApps.onMicrophone([
            sig("com.apple.CoreSpeech"),
            sig("com.electron.wispr-flow.helper"),
        ])
        #expect(calls.isEmpty)
    }

    /// A call app that only plays audio — a message tone, a video — has
    /// no microphone to give back.
    @Test func outputOnlyIsNotOnTheMic() {
        let calls = CallApps.onMicrophone([sig("us.zoom.xos", input: false, output: true)])
        #expect(calls.isEmpty)
    }

    /// A browser's audio runs in a helper process, and a browser holding
    /// the microphone is treated as a call here: the cost of being wrong
    /// is a leak, the cost of the other mistake is a silent user.
    @Test func browserHelperCounts() {
        let calls = CallApps.onMicrophone([sig("com.google.Chrome.helper.plugin")])
        #expect(calls.map(\.name) == ["Chrome"])
    }

    @Test func eachAppOnce() {
        let calls = CallApps.onMicrophone([
            sig("com.tdesktop.Telegram"), sig("com.tdesktop.Telegram"), sig("com.apple.FaceTime"),
        ])
        #expect(calls.map(\.name) == ["Telegram", "FaceTime"])
    }

    /// Nothing on the microphone at all: the meeting keeps its canceller.
    @Test func emptyMeansEchoCancelStays() {
        #expect(CallApps.onMicrophone([]).isEmpty)
        #expect(CallApps.onMicrophone([sig("com.apple.Music", input: false)]).isEmpty)
    }
}
