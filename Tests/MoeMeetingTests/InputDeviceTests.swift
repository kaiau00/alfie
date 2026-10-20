import Foundation
import Testing
@testable import MoeMeeting

// MARK: - Which device the log names


struct InputDevicePickTests {

    private func device(_ name: String) -> AudioDeviceInfo {
        AudioDeviceInfo(id: 1, name: name, uid: name, transport: "built-in")
    }

    /// The bug, in one line: a voice processing unit answers `deviceID` with
    /// the *output* device, and the meeting log named "MacBook Air Speakers"
    /// as the microphone it had opened. A device with no input channels
    /// cannot be the microphone, whatever the audio unit says.
    @Test func aDeviceWithNoInputChannelsIsNotTheMicrophone() {
        let picked = AudioDevices.pickInput(reported: device("MacBook Air Speakers"),
                                            reportedInputChannels: 0,
                                            defaultInput: device("MacBook Air Microphone"))
        #expect(picked?.name == "MacBook Air Microphone")
    }

    @Test func aDeviceThatCouldBeAMicrophoneIsBelieved() {
        let picked = AudioDevices.pickInput(reported: device("Shure MV7"),
                                            reportedInputChannels: 1,
                                            defaultInput: device("MacBook Air Microphone"))
        #expect(picked?.name == "Shure MV7")
    }

    @Test func nothingReportedFallsBackToTheDefaultInput() {
        let picked = AudioDevices.pickInput(reported: nil, reportedInputChannels: 0,
                                            defaultInput: device("MacBook Air Microphone"))
        #expect(picked?.name == "MacBook Air Microphone")
        #expect(AudioDevices.pickInput(reported: nil, reportedInputChannels: 0, defaultInput: nil) == nil)
    }
}
