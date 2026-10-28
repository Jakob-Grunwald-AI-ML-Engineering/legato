import Foundation

/// A real executable bundle supplies Bundle.main's identity, so a hardcoded production note fails here.
@main struct RuntimeIdentityContractTests {
    static func main() {
        let expectedNamespace = CommandLine.arguments[1]
        guard RuntimeIdentity.current.notificationNamespace == expectedNamespace else {
            print("FAIL: test bundle identity was not loaded")
            exit(2)
        }
        let notes: [(String, String)] = [
            ("host", LinkChannel.Note.host), ("request", LinkChannel.Note.request),
            ("ack", LinkChannel.Note.ack), ("presence", LinkChannel.Note.presence),
            ("applied", LinkChannel.Note.applied), ("refine", LinkChannel.Note.refine),
            ("refined", LinkChannel.Note.refined), ("choice", LinkChannel.Note.choice),
        ]
        var failures = 0
        for (suffix, actual) in notes {
            let expected = "\(expectedNamespace).link.\(suffix)"
            if actual != expected {
                print("FAIL: \(suffix): expected \(expected), got \(actual)")
                failures += 1
            }
        }
        guard failures == 0 else { exit(1) }
        print("PASS: all \(notes.count) actual Darwin notes use \(expectedNamespace)")
    }
}
