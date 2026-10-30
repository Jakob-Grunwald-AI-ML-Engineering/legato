import Foundation
import Testing
import LegatoCore
import LegatoRoom
import LegatoAudio
@testable import LegatoAppServices

@MainActor @Test func composerReusesArmedMicrophoneWithoutReactivatingBackgroundSession() async throws {
    let mic = ComposerTestMicrophone()
    var activations = 0
    let session = ComposerSession(microphone: mic, activateAudioSession: {
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
    let session = ComposerSession(microphone: mic, activateAudioSession: {})
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
    let session = ComposerSession(microphone: ComposerTestMicrophone(), activateAudioSession: {
        throw NSError(domain: NSOSStatusErrorDomain, code: 560_557_684)
    })
    await session.arm()
    #expect(session.status == "error")
    #expect(session.error?.contains("Open Legato") == true)
    #expect(session.error?.contains("microphone") == true)
    #expect(!session.isArmed)
}

@MainActor @Test func composerBackgroundOptOutStopsNewInputWithoutDiscardingDraft() async throws {
    let mic = ComposerTestMicrophone()
    let session = ComposerSession(microphone: mic, activateAudioSession: {})
    await session.arm()
    let room = Room()
    await session.receive(try await room.publish(channel: .session, participant: .ui, payload: .object(["state": .string("listening")])))
    await session.setKeepMicrophoneActive(false)
    #expect(session.isListening, "Disabling retention must not interrupt a foreground session")
    await session.prepareForBackground()
    #expect(!session.isListening)
    #expect(!session.isArmed)
    #expect(session.status == "trailing", "Background opt-out drains instead of discarding agent work")
    #expect(await mic.stops > 0)
}

@MainActor @Test func composerLostArmedRouteClearsLeaseWithoutReactivationLoop() async throws {
    let mic = ComposerTestMicrophone()
    var activations = 0
    let session = ComposerSession(microphone: mic, activateAudioSession: { activations += 1 })
    await session.arm()
    await mic.loseRoute()
    await #expect(throws: MicSourceError.notArmed) { _ = try await session.prepareMicrophoneStream() }
    #expect(!session.isArmed)
    #expect(activations == 1)
    #expect(await mic.stops == 1)
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
