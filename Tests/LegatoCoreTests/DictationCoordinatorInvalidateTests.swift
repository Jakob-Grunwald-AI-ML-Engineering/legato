import Foundation
import Testing
@testable import LegatoCore

/// A setting that the session is built from changed (the speech model, its languages, the silence wait):
/// no session built before the change may be kept or reused after it.
@MainActor
@Suite struct DictationCoordinatorInvalidateTests {
    static let keepAlive = StartOptions(keepAlive: .seconds(30))

    private func runOnce(_ r: CoordinatorRig) async {
        #expect(await r.coordinator.toggle(Self.keepAlive) == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
    }

    @Test func whileIdleTheHeldSessionIsReleasedAtOnce() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        await runOnce(r)
        #expect(r.coordinator.holdsLease)
        await r.coordinator.invalidateKeptSession()
        #expect(!r.coordinator.holdsLease)
        #expect(r.log.count("deactivate") == 1)
        #expect(r.sink.leases.map { $0 != nil } == [true, false])
        await runOnce(r)
        #expect(r.built.all.count == 2, "the next start builds a session from the new settings")
    }

    @Test func duringARunTheRunsSessionIsReleasedWhenItEndsInsteadOfKept() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        r.attachSink()
        #expect(await r.coordinator.toggle(Self.keepAlive) == .started)
        await r.coordinator.invalidateKeptSession()
        #expect(r.log.count("deactivate") == 0, "the run goes on")
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(!r.coordinator.holdsLease)
        #expect(r.log.count("deactivate") == 1)
        #expect(r.sink.leases.allSatisfy { $0 == nil })
        await runOnce(r)
        #expect(r.built.all.count == 2)
    }

    @Test func aRunOnAHeldSessionThatWentStaleMidRunIsNotKeptEither() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        await runOnce(r)
        #expect(await r.coordinator.toggle(Self.keepAlive) == .started) // reuses the held session
        #expect(r.built.all.count == 1)
        await r.coordinator.invalidateKeptSession()
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        #expect(!r.coordinator.holdsLease)
        await runOnce(r)
        #expect(r.built.all.count == 2)
    }

    @Test func onlyTheChangeBeforeTheRunCounts() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello world", isFinal: true)])
        #expect(await r.coordinator.toggle(Self.keepAlive) == .started)
        await r.coordinator.invalidateKeptSession()
        #expect(await r.coordinator.toggle() == .stopped("hello world"))
        await runOnce(r) // built after the change: kept as usual
        #expect(r.coordinator.holdsLease)
        await runOnce(r)
        #expect(r.built.all.count == 2)
    }

    @Test func withNothingHeldItDoesNothing() async throws {
        let r = CoordinatorRig()
        r.attachSink()
        await r.coordinator.invalidateKeptSession()
        #expect(r.log.events.isEmpty)
    }
}
