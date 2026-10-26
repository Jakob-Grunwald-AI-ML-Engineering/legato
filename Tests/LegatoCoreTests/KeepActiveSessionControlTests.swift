import Foundation
import Synchronization
import Testing
@testable import LegatoCore

/// A switch a test flips while the control is in use.
final class Switch: Sendable {
    private let value: Mutex<Bool>
    init(_ on: Bool) { value = Mutex(on) }
    var isOn: Bool { value.withLock { $0 } }
    func set(_ on: Bool) { value.withLock { $0 = on } }
}

/// The audio session of the device bug: a session left active between runs, then a background start.
/// The fake inner control refuses any activation while the session is active, as iOS does for a
/// background `setCategory` on an active session ('!int'), even with unchanged values.
@MainActor
private struct HeldRig {
    let log = EventLog()
    let engine: FakeEngine
    let source: FakeSource
    let inner: FakeSessionControl
    let control: KeepActiveSessionControl
    let keep = Switch(true)
    let liveInput = Switch(true)
    let history = MemoryHistory()
    static let refused = TestError(tag: "refused")

    init(refuse: Bool = true) {
        engine = FakeEngine(log: log)
        engine.set(script: [.init(text: "hello", isFinal: true)])
        source = FakeSource(log: log)
        let inner = FakeSessionControl(log: log)
        if refuse { inner.refuseActivationWhileActive(with: Self.refused) }
        self.inner = inner
        let keep = self.keep, liveInput = self.liveInput
        control = KeepActiveSessionControl(
            inner: inner, keepActive: { keep.isOn }, hasLiveInput: { liveInput.isOn },
            isRefusal: { ($0 as? TestError)?.tag == "refused" })
    }

    /// A fresh session per dictation, like the app builds them, all over the one control.
    func session(_ policy: AudioPolicy = .duckOthers) -> DictationSession {
        DictationSession(engine: engine, source: source, sessionControl: control, history: history, policy: policy)
    }

    func run(_ policy: AudioPolicy = .duckOthers) async throws {
        let s = session(policy)
        try await s.start()
        _ = try await s.stop()
    }
}

@MainActor
@Suite struct KeepActiveSessionControlTests {
    @Test func aStartOnAHeldActiveSessionDoesNotReconfigureIt() async throws {
        let r = HeldRig()
        try await r.run()
        #expect(r.control.isHeld && r.inner.isActive) // the stop left the session active
        #expect(r.log.count("activate") == 1)

        try await r.run() // the second press, same policy: iOS would refuse a setCategory now
        #expect(r.log.count("activate") == 1) // nothing re-ran
        #expect(r.log.count("deactivate") == 0)
        #expect(r.log.count("source.start") == 2)
    }

    @Test func aRefusedReconfigureOfAHeldSessionStartsOnTheConfigurationInPlace() async throws {
        let r = HeldRig()
        try await r.run(.duckMusicPauseSpoken)
        try await r.run(.duckOthers) // a different configuration, refused by the system
        #expect(r.log.count("activate") == 2) // it was tried
        #expect(r.inner.activatedConfigs == [AudioPolicy.duckMusicPauseSpoken.sessionConfig])
        #expect(r.log.count("source.start") == 2) // and the start went on
    }

    @Test func aReconfigureThatTheSystemAllowsIsApplied() async throws {
        let r = HeldRig(refuse: false)
        try await r.run(.duckMusicPauseSpoken)
        try await r.run(.duckOthers)
        #expect(r.inner.activatedConfigs == [AudioPolicy.duckMusicPauseSpoken.sessionConfig, AudioPolicy.duckOthers.sessionConfig])
        try await r.run(.duckOthers) // and is the configuration in place now: nothing re-runs
        #expect(r.log.count("activate") == 2)
    }

    @Test func aHeldSessionWithoutInputIsDeactivatedAndActivatedAgain() async throws {
        let r = HeldRig()
        try await r.run()
        r.liveInput.set(false) // the route lost its input while the session was held
        try await r.run()
        let ev = r.log.events.filter { $0 == "activate" || $0 == "deactivate" }
        #expect(ev == ["activate", "deactivate", "activate"])
        #expect(r.inner.isActive)
    }

    @Test func anActivationErrorThatIsNoRefusalStillFailsTheStart() async throws {
        let r = HeldRig(refuse: false)
        try await r.run(.duckMusicPauseSpoken)
        r.inner.failActivation(with: TestError(tag: "boom"))
        await #expect(throws: TestError(tag: "boom")) { try await r.run(.duckOthers) }
    }

    @Test func aRefusalWithNothingHeldStillFailsTheStart() async throws {
        let r = HeldRig(refuse: false)
        r.inner.failActivation(with: HeldRig.refused)
        await #expect(throws: HeldRig.refused) { try await r.run() }
    }

    @Test func aSystemEventReleasesAHeldSessionForReal() async throws {
        let r = HeldRig()
        try await r.run()
        r.control.release(reason: "interruption began")
        #expect(r.log.count("deactivate") == 1 && !r.inner.isActive && !r.control.isHeld)
        try await r.run() // activated from scratch, not reused
        #expect(r.log.count("activate") == 2)
    }

    @Test func withoutTheSwitchAStopDeactivatesForReal() async throws {
        let r = HeldRig()
        r.keep.set(false)
        try await r.run()
        #expect(r.log.count("deactivate") == 1 && !r.inner.isActive && !r.control.isHeld)
    }

    @Test func releasingAHeldSessionWhenTheSwitchGoesOffDeactivatesIt() async throws {
        let r = HeldRig()
        try await r.run()
        r.control.releaseIfHeld()
        #expect(r.log.count("deactivate") == 1 && !r.inner.isActive)
    }
}

@MainActor
@Suite struct HeldSessionCoordinatorTests {
    /// The device bug end to end: no keep-ready lease, the keep-active switch holds the audio session, and
    /// a press in the background must start without opening the app.
    @Test func aBackgroundPressOnAHeldSessionStartsWithoutAHop() async throws {
        let keep = Switch(true)
        let r = CoordinatorRig(script: [.init(text: "hello", isFinal: true)], wrapControl: { fake in
            fake.refuseActivationWhileActive(with: HeldRig.refused)
            return KeepActiveSessionControl(
                inner: fake, keepActive: { keep.isOn }, isRefusal: { ($0 as? TestError)?.tag == "refused" })
        })
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false, audioPolicy: .duckMusicPauseSpoken)
        #expect(await r.coordinator.toggle() == .started)
        #expect(await r.coordinator.toggle() == .stopped("hello"))
        #expect(r.control.isActive) // left active

        #expect(await r.coordinator.toggle() == .started) // the second background press
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") }.isEmpty)
        #expect(r.log.count("activity.dismiss") == 0)
        #expect(r.log.count("activate") == 1)
        #expect(await r.coordinator.toggle() == .stopped("hello"))
    }

    @Test func aDifferentSelectedPolicyInTheBackgroundAlsoStartsOnTheHeldSession() async throws {
        let r = CoordinatorRig(script: [.init(text: "hello", isFinal: true)], wrapControl: { fake in
            fake.refuseActivationWhileActive(with: HeldRig.refused)
            return KeepActiveSessionControl(
                inner: fake, keepActive: { true }, isRefusal: { ($0 as? TestError)?.tag == "refused" })
        })
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false, audioPolicy: .duckMusicPauseSpoken)
        #expect(await r.coordinator.toggle() == .started)
        _ = await r.coordinator.toggle()
        r.environment.context = StartContext(inBackground: true, otherAudioPlaying: false, audioPolicy: .duckOthers)
        #expect(await r.coordinator.toggle() == .started) // reconfigure refused, carried on in place
        #expect(r.log.events.filter { $0.hasPrefix("fallback:") }.isEmpty)
        _ = await r.coordinator.toggle()
    }
}
