import Foundation
import Testing
@testable import LegatoAppServices

@MainActor @Suite struct DictationRouteSessionTests {
    @Test func sharedRouteKeepsMagicSpeechOutOfDictationAndResetsForNextTake() async {
        let sink = DiscardingDictationSink()
        let sockets = SocketBox()
        let instruction = InstructionSession(vocabularyURL: URL(fileURLWithPath: "/nonexistent/vocabulary.json"))
        let route = DictationRouteSession(sink: sink, instruction: instruction, sonioxKey: { "" },
                                         makeSocket: { sockets.make() }, vocabularyURL: URL(fileURLWithPath: "/nonexistent/vocabulary.json"))
        #expect(await route.engine.debugLine("words for the field"))
        #expect(sink.received == 1)
        route.setMagic(true, cut: false)
        #expect(await route.engine.debugLine("make it shorter"))
        #expect(sink.received == 1)
        #expect(instruction.strip.transcript == "make it shorter")
        await route.reset()
        #expect(route.speechMode == .dictation)
        #expect(instruction.strip.phase == .idle)
        #expect(await route.engine.debugLine("another take"))
        #expect(sink.received == 2)
        #expect(sockets.count == 0, "Debug input never starts a provider connection")
    }
}
