import Foundation
import Testing
import LegatoCore
import LegatoRoom
import LegatoAudio
@testable import LegatoAppServices

@MainActor @Test func composerReusesArmedMicrophoneWithoutReactivatingBackgroundSession() async throws {
    let mic = ComposerTestMicrophone()
    var activations = 0
    let session = MicrophoneHost(microphone: mic, activateAudioSession: {
        activations += 1
        if activations > 1 { throw NSError(domain: NSOSStatusErrorDomain, code: 560_557_684) }
    })
    await session.arm()
    #expect(session.isArmed)
    _ = try await session.prepareMicrophoneStream()
    #expect(activations == 1, "The armed session must not be reconfigured when the keyboard starts in the background")
    #expect(await mic.starts == 1)
    #expect(await mic.routes == 1)
    await session.releaseMicrophone()
}

@MainActor @Test func composerDisabledBackgroundLeaseReleasesIdleMicAndStopsOnBackground() async throws {
    let mic = ComposerTestMicrophone()
    let session = MicrophoneHost(microphone: mic, activateAudioSession: {})
    await session.arm()
    await session.setKeepMicrophoneActive(false)
    #expect(!session.isArmed)
    #expect(await mic.stops > 0)
    await session.arm()
    await session.prepareForBackground()
    #expect(!session.isArmed)
    #expect(session.status == "ready", "Releasing a ready lease need not erase the composition")
}

@MainActor @Test func composerBackgroundRefusalGivesForegroundRecoveryInstruction() async {
    let session = MicrophoneHost(microphone: ComposerTestMicrophone(), activateAudioSession: {
        throw NSError(domain: NSOSStatusErrorDomain, code: 560_557_684)
    })
    await session.arm()
    #expect(session.status == "error")
    #expect(session.error?.contains("Open Legato") == true)
    #expect(session.error?.contains("microphone") == true)
    #expect(!session.isArmed)
}

@MainActor @Test func composerLostArmedRouteRebuildsWithoutReconfiguringBackgroundSession() async throws {
    let mic = ComposerTestMicrophone()
    var activations = 0
    let session = MicrophoneHost(microphone: mic, activateAudioSession: { activations += 1 })
    await session.arm()
    await mic.loseRoute()
    _ = try await session.prepareMicrophoneStream()
    #expect(session.isArmed)
    #expect(session.error == nil)
    #expect(activations == 1, "Repair reuses the active audio session instead of a forbidden background reconfiguration")
    #expect(await mic.starts == 2)
    #expect(await mic.stops == 1)
    await session.releaseMicrophone()
}

private actor ComposerTestMicrophone: AudioSource {
    var starts = 0
    var routes = 0
    var stops = 0
    var routeLost = false
    func loseRoute() { routeLost = true }
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> { starts += 1; return AsyncStream { $0.finish() } }
    func route() async throws -> AsyncStream<AudioChunk> { routes += 1; if routeLost { throw MicSourceError.notArmed }; return AsyncStream { $0.finish() } }
    func detach() async {}
    func stop() async { stops += 1 }
}

@MainActor @Test func transientStartupCancellationRetriesWithoutShowingSwiftError() async {
    let mic = TransientMicrophone()
    let session = MicrophoneHost(microphone: mic, activateAudioSession: {})
    await session.arm()
    #expect(session.isArmed)
    #expect(!session.microphoneRecovering)
    #expect(session.error == nil)
    #expect(await mic.starts == 2)
    await session.releaseMicrophone()
}

@MainActor @Test func releasingDuringAdmissionCannotRearmOrPublishAnError() async throws {
    let admission = MicrophoneAdmissionGate()
    let mic = TransientMicrophone()
    let session = MicrophoneHost(microphone: mic, activateAudioSession: { await admission.wait() })
    let arm = Task { await session.arm() }
    while !(await admission.waiting) { await Task.yield() }
    await session.releaseMicrophone()
    await admission.release()
    await arm.value
    #expect(!session.isArmed && !session.microphoneRecovering)
    #expect(session.error == nil)
    #expect(await mic.starts == 0)
}

private actor TransientMicrophone: AudioSource {
    var starts = 0
    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        starts += 1
        if starts == 1 { throw CancellationError() }
        return AsyncStream { $0.finish() }
    }
    func route() async throws -> AsyncStream<AudioChunk> { AsyncStream { $0.finish() } }
    func detach() async {}
    func stop() async {}
}
private actor MicrophoneAdmissionGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Test func repeatedArmDoesNotStealTheCurrentAudioStream() async {
    let mic = ComposerTestMicrophone()
    let session = MicrophoneHost(microphone: mic, activateAudioSession: {})
    await session.arm()
    await session.arm()
    #expect(await mic.starts == 1)
    #expect(await mic.routes == 0)
    #expect(session.isArmed)
    await session.releaseMicrophone()
}

/// The retained microphone policy from the retired composition test: foreground capture continues,
/// while backgrounding releases it when retention is disabled.
@MainActor @Test func microphoneBackgroundOptOutKeepsForegroundTakeThenReleasesCapture() async throws {
    let mic = GateMicrophone()
    let host = MicrophoneHost(microphone: mic, activateAudioSession: {})
    await host.arm()
    #expect(await host.holdWarmInput())
    host.setRoute(.dictation)
    await host.setKeepMicrophoneActive(false)
    #expect(host.isListening && host.isArmed)
    await host.prepareForBackground()
    #expect(!host.isListening && !host.isArmed)
    #expect(await mic.stops > 0)
}
