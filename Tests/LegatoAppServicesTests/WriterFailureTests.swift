import Testing
@testable import LegatoAppServices

@Test func writerFailuresBecomeShortHumanMessages() {
    let unauthorized = #"http(401, "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}")"#
    #expect(ComposerSession.writerFailureMessage(unauthorized) == "Claude key rejected")
    #expect(ComposerSession.writerFailureMessage("missingKey") == "Add your Claude key in Legato")
    #expect(ComposerSession.writerFailureMessage(#"http(429, "rate_limit_error")"#) == "Claude is busy — try again")
    #expect(ComposerSession.writerFailureMessage("Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\"") == "Network unavailable")
    #expect(ComposerSession.writerFailureMessage(#"provider("{\"weird\":1}")"#) == "Writer failed — try again")
}
