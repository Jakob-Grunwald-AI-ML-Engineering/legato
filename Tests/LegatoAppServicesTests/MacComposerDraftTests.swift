import Foundation
import Testing
import LegatoAgent
import LegatoClaude
import LegatoRoom
import Synchronization
@testable import LegatoAppServices

private final class WritingRequestRecorder: MessagesStreaming {
    let bodies = Mutex<[Data]>([])
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        bodies.withLock { $0.append(request) }
        return AsyncThrowingStream { $0.finish(throwing: SentenceCleanupError.providerError) }
    }
}

@MainActor struct MacComposerDraftTests {
    private func session(_ cleaner: any SentenceCleaning, defaults: UserDefaults = .standard) -> (MacDictationSession, MacComposerDraft) {
        let draft = MacComposerDraft(defaults: defaults)
        let sockets = SocketBox()
        let session = MacDictationSession(pipeline: DictationPipeline(cleaner: cleaner), microphone: MacMic(),
                                          vocabularyURL: URL(fileURLWithPath: "/nonexistent/vocabulary.json"), composer: draft,
                                          sonioxKey: { "" }, makeSocket: { sockets.make() }, warmConnection: {})
        return (session, draft)
    }

    @Test func stoppedSpeechPersistsAndRepeatedMagicRevisesTheWholeDraftBeforeExplicitInsertion() async throws {
        let cleaner = Cleaner()
        let (session, draft) = session(cleaner)
        var captures = 0, inserts: [String] = []
        session.onBegin = { captures += 1 }
        session.insertDraftText = { inserts.append($0); return true }
        try await session.debugLine("one")
        await session.debugStop()
        try await session.debugLine("two")
        await session.debugStop()
        #expect(draft.text == "one two")
        #expect(captures == 1 && inserts.isEmpty && cleaner.inputs.withLock { $0.isEmpty })
        await session.magicDraft()
        await draft.settleCorrection()
        #expect(draft.text == "One two.")
        try await session.debugLine("three")
        await session.magicDraft()
        await draft.settleCorrection()
        #expect(cleaner.inputs.withLock { $0.map(\.text) } == ["one two", "One two. three"])
        #expect(inserts.isEmpty)
        await session.insertDraft()
        await session.insertDraft()
        #expect(inserts == ["One two. three."] && draft.isEmpty)
    }

    @Test func discardRevokesStreamingWorkAndUndoRestoresTheStableSource() async throws {
        let cleaner = Cleaner(slow: ["hello"])
        let (session, draft) = session(cleaner)
        try await session.debugLine("hello")
        await session.magicDraft()
        #expect(draft.isCorrecting)
        await session.discardDraft()
        #expect(draft.isEmpty && draft.canUndoDiscard && !draft.isCorrecting)
        session.undoDiscard()
        #expect(draft.text == "hello")
        session.insertDraftText = { _ in false }
        await session.insertDraft()
        #expect(draft.needsCopy && draft.text == "hello")
        await session.discardDraft()
        session.undoDiscard()
        #expect(draft.needsCopy)
    }

    @Test func lateCompletionOfFirstCutCannotConsumeTheSecondBoundary() async {
        let draft = MacComposerDraft()
        var firstRequest: CheckedContinuation<Bool, Never>?
        let first = Task {
            await draft.finalizeForMagic { await withCheckedContinuation { firstRequest = $0 } }
        }
        while firstRequest == nil { await Task.yield() }
        draft.boundary("finalize")
        #expect(await first.value)
        let second = Task { await draft.finalizeForMagic { true } }
        while draft.onCut == nil { await Task.yield() }
        firstRequest?.resume(returning: false)
        await Task.yield()
        draft.boundary("finalize")
        #expect(await second.value)
    }

    @Test func spokenInstructionEditsOnlyTheStagedDraft() async throws {
        let cleaner = DebugStreamingCleaner(chunkMilliseconds: 1)
        let (session, draft) = session(cleaner)
        try await session.debugLine("hello")
        #expect(await session.startMagic())
        try await session.debugLine("uppercase")
        #expect(session.instruction.transcript == "uppercase" && draft.text == "hello")
        await session.endMagic()
        await draft.settleCorrection()
        #expect(draft.text == "HELLO" && session.isActive)
        await session.debugStop()
    }

    @Test func magicAndSpokenInstructionsReadTheCurrentMacWritingPreferences() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        func set(_ model: ModelChoice, _ preference: String) {
            defaults.setVolatileDomain(["composer.liveModel": model.rawValue, "composer.personalPrompt": preference],
                                       forName: UserDefaults.argumentDomain)
        }
        let recorder = WritingRequestRecorder()
        let (session, draft) = session(SentenceCleanupClient(client: recorder, model: { .haiku }), defaults: defaults)
        set(.sonnet, "Use short paragraphs.")
        try await session.debugLine("sample draft")
        await session.magicDraft()
        await draft.settleCorrection()
        set(.opus, "Use British spelling.")
        #expect(await session.startMagic())
        try await session.debugLine("make it polite")
        await session.endMagic()
        await draft.settleCorrection()
        let requests = try recorder.bodies.withLock { bodies in try bodies.map { try JSONDecoder().decode(JSONValue.self, from: $0) } }
        #expect(requests.count == 2)
        for (request, expected) in zip(requests, [(ModelChoice.sonnet, "Use short paragraphs."), (.opus, "Use British spelling.")]) {
            #expect(request["model"] == .string(expected.0.rawValue))
            let blocks = try #require(request["system"]).decode([JSONValue].self)
            let system = try #require(blocks.first?["text"]).decode(String.self)
            #expect(system.contains(expected.1))
        }
        let messages = try #require(requests.last?["messages"]).decode([JSONValue].self)
        let data = try #require(messages.first?["content"]).decode(String.self)
        let raw = try JSONDecoder().decode(JSONValue.self, from: Data(data.utf8))
        #expect(raw["instructions"] == .string("make it polite") && raw["text"] == .string("sample draft"))
        await session.debugStop()
    }

    @Test func chordingDuringAnInstructionPreservesTheRunningTakeWithoutRunningMagic() async throws {
        let cleaner = Cleaner()
        let (session, draft) = session(cleaner)
        try await session.debugLine("before")
        #expect(await session.startMagic())
        try await session.debugLine("unintended instruction")
        await session.endMagic(discard: true)
        #expect(session.phase == .listening && session.speechMode == .dictation)
        try await session.debugLine("after")
        await session.debugStop()
        #expect(draft.text == "before after" && cleaner.inputs.withLock { $0.isEmpty })
    }

    @Test func protectedDraftSkipsProvidersAndVoiceInstructions() async throws {
        let cleaner = Cleaner()
        let (session, draft) = session(cleaner)
        session.pipeline.keepsTakes = { false }
        try await session.debugLine("secret")
        await session.magicDraft()
        #expect(await session.startMagic() == false)
        #expect(draft.text == "secret" && !draft.isCorrecting && cleaner.inputs.withLock { $0.isEmpty })
        await session.debugStop()
    }
}
