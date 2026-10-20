import Foundation
import Testing
import MoeObjC

/// The wrapper every `installTap` goes through. An Objective-C exception
/// Swift never sees is how a microphone change crashed Moe minutes later in
/// SwiftUI (2026-09-30 15:57); these prove it arrives as a Swift error.
@Suite struct MoeObjCTests {

    @Test func anExceptionBecomesAnError() throws {
        var thrown: Error?
        do {
            try MoeObjC.catchException {
                NSException(name: .invalidArgumentException,
                            reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
                            userInfo: nil).raise()
            }
        } catch {
            thrown = error
        }
        let e = try #require(thrown) as NSError
        #expect(e.domain == MoeObjCExceptionErrorDomain)
        #expect(e.localizedDescription.contains("format.sampleRate"))
        #expect(e.userInfo["MoeObjCExceptionName"] as? String
                == NSExceptionName.invalidArgumentException.rawValue)
    }

    @Test func aBlockThatFinishesThrowsNothingAndRan() throws {
        var ran = false
        try MoeObjC.catchException { ran = true }
        #expect(ran)
    }
}
