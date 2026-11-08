import Foundation
import Testing
import LegatoCore
@testable import LegatoAppServices

@MainActor private func until(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<5000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
    Issue.record("Timed out waiting for condition")
    throw CancellationError()
}

/// Records the policy calls and the composer's route at the moment each one runs.
@MainActor final class RouteRecorder {
    var events: [String] = []
    var routeAtTake: AudioRoute?
    weak var composer: ComposerSession?
    /// A refusing policy still returns normally: refusal is logged by the policy and the take carries on.
    var policy: InputRoutePolicy {
        InputRoutePolicy(
            preferIdle: { [self] in events.append("idle") },
            preferTake: { [self] in events.append("take"); routeAtTake = composer?.route })
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct InputRoutePolicyTests {
    let mic = GateMicrophone()
    let sockets = SocketBox()
    let sink = RecordingSink()
    let recorder = RouteRecorder()

    private func open(policy: InputRoutePolicy?) async throws -> (ComposerSession, KeyboardSession) {
        let composer = ComposerSession(microphone: mic, activateAudioSession: {})
        recorder.composer = composer
        if let policy { composer.inputRoute = policy }
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(composer: composer, sink: sink, sonioxKey: { "test" },
                                       makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        try await until { await sockets.last?.held == true }
        return (composer, keyboard)
    }

    @Test func theIdleHoldPrefersTheBuiltInInput() async throws {
        let (composer, _) = try await open(policy: recorder.policy)
        #expect(composer.holdsWarmInput)
        #expect(recorder.events.last == "idle")
        #expect(!recorder.events.contains("take"), "Holding the mic is not a take")
    }

    @Test func openingATakePrefersTheTakeInputBeforeAudioRoutes() async throws {
        let (composer, keyboard) = try await open(policy: recorder.policy)
        recorder.events.removeAll()
        #expect(await keyboard.openGate(tapAt: Date()))
        #expect(recorder.events == ["take"])
        #expect(recorder.routeAtTake == .idle, "The switch happens while the gate is still closed")
        #expect(composer.route == .dictation)
    }

    @Test func closingTheTakeReturnsToTheIdleInput() async throws {
        let (composer, keyboard) = try await open(policy: recorder.policy)
        _ = await keyboard.openGate(tapAt: Date())
        recorder.events.removeAll()
        await keyboard.closeGate()
        #expect(recorder.events == ["idle"])
        #expect(composer.route == .idle)
    }

    @Test func aTakeThatCannotStartReturnsToTheIdleInput() async throws {
        let composer = ComposerSession(microphone: mic, activateAudioSession: {})
        composer.inputRoute = recorder.policy
        await composer.arm()
        let sockets = self.sockets
        let keyboard = KeyboardSession(composer: composer, sink: sink, sonioxKey: { "" },
                                       makeSocket: { sockets.make() }, warmConnection: {})
        keyboard.update(visible: true, surface: .dictation)
        await keyboard.settle()
        recorder.events.removeAll()
        _ = await keyboard.openGate(tapAt: Date())
        #expect(recorder.events == ["take", "idle"])
    }

    @Test func aRefusedSwitchDoesNotBreakTheTake() async throws {
        // A refusing policy swallows the failure (the iOS one logs it) and the take runs on the live input.
        let (composer, keyboard) = try await open(policy: recorder.policy)
        let socket = try #require(sockets.last)
        #expect(await keyboard.openGate(tapAt: Date()))
        await mic.emit()
        try await until { await socket.audioFrames > 0 }
        #expect(composer.route == .dictation)
        await keyboard.closeGate()
        #expect(composer.route == .idle)
    }

    @Test func theDefaultPolicyChangesNothing() async throws {
        let (composer, keyboard) = try await open(policy: nil)
        let socket = try #require(sockets.last)
        #expect(await keyboard.openGate(tapAt: Date()))
        await mic.emit()
        try await until { await socket.audioFrames > 0 }
        await keyboard.closeGate()
        #expect(composer.route == .idle && composer.holdsWarmInput)
        #expect(recorder.events.isEmpty)
    }
}
