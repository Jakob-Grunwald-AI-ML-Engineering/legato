import Foundation
import LegatoFieldEdit
import Testing
@testable import LegatoMac

@MainActor
private final class FakeActivitySource: FieldActivitySource {
    var handler: (@MainActor () -> Void)?
    private(set) var stopped = false
    func start(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    func stop() { stopped = true; handler = nil }
    func fire() { handler?() }
}

@MainActor
private final class Clock {
    var now: TimeInterval = 100
}

/// Mac typing guard: user activity (AX value/selection notifications) holds non-user writes until the field
/// has been quiet for 0.3 s; user commands are never held.
@MainActor
@Suite struct TypingGuardTests {
    private func makeGuard(quiet: TimeInterval = 0.3) -> (TypingGuard, FakeActivitySource, Clock) {
        let source = FakeActivitySource()
        let clock = Clock()
        let guardian = TypingGuard(source: source, quiet: quiet, now: { clock.now })
        return (guardian, source, clock)
    }

    @Test func quietFieldHoldsNothing() {
        let (guardian, _, _) = makeGuard()
        for origin in EditOrigin.allCases { #expect(guardian.delay(for: origin) == 0) }
    }

    @Test func defaultQuietIntervalIs300Milliseconds() {
        #expect(TypingGuard.defaultQuiet == 0.3)
    }

    @Test func activityHoldsAgentWritesUntilQuiet() {
        let (guardian, source, clock) = makeGuard()
        source.fire()
        clock.now += 0.1
        #expect(abs(guardian.delay(for: .agent) - 0.2) < 1e-9)
        clock.now += 0.2 + 1e-6
        #expect(guardian.delay(for: .agent) == 0)
    }

    @Test func everyNonUserOriginIsHeld() {
        let (guardian, source, _) = makeGuard()
        source.fire()
        for origin in EditOrigin.allCases where !origin.isUser {
            #expect(guardian.delay(for: origin) > 0, "\(origin)")
        }
    }

    @Test func userCommandsAreNeverHeld() {
        let (guardian, source, _) = makeGuard()
        source.fire()
        for origin in EditOrigin.allCases where origin.isUser {
            #expect(guardian.delay(for: origin) == 0, "\(origin)")
        }
    }

    @Test func newActivityExtendsTheHold() {
        let (guardian, source, clock) = makeGuard()
        source.fire()
        clock.now += 0.25
        source.fire()
        clock.now += 0.25
        #expect(guardian.delay(for: .liveCleanup) > 0)
        clock.now += 0.06
        #expect(guardian.delay(for: .liveCleanup) == 0)
    }

    @Test func echoOfOurOwnWriteIsNotUserActivity() {
        let (guardian, source, _) = makeGuard()
        guardian.isEcho = { true }
        source.fire()
        #expect(guardian.delay(for: .agent) == 0)
        guardian.isEcho = { false }
        source.fire()
        #expect(guardian.delay(for: .agent) > 0)
    }

    @Test func stopDetachesFromTheSource() {
        let (guardian, source, _) = makeGuard()
        guardian.stop()
        #expect(source.stopped)
        source.fire()
        #expect(guardian.delay(for: .agent) == 0)
    }
}
