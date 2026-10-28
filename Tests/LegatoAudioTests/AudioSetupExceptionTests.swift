import Foundation
import LegatoAudioBridge
import Testing

@Suite struct AudioSetupExceptionTests {
    @Test func nativeSetupExceptionBecomesAnErrorAndAllowsTheNextAttempt() throws {
        let error = LegatoAudioCatchException {
            NSException(name: .internalInconsistencyException,
                reason: "Failed to create tap due to format mismatch", userInfo: nil).raise()
        }
        let failure = try #require(error) as NSError
        #expect(failure.domain == "LegatoAudio.NativeSetup")
        #expect(failure.code == 1)
        #expect(failure.localizedDescription == "Failed to create tap due to format mismatch")
        #expect(failure.userInfo["exceptionName"] as? String == "NSInternalInconsistencyException")
        #expect(LegatoAudioCatchException {} == nil)
    }
}
