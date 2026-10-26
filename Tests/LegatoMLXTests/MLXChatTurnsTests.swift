import LegatoCore
import MLXLMCommon
import Testing
@testable import LegatoMLX

@Suite("MLXBackend chat turns")
struct MLXChatTurnsTests {
    @Test func examplesBecomeUserAndAssistantTurnsAheadOfThePrompt() {
        let messages = MLXBackend.chatMessages(
            examples: [
                LLMExample(user: "in one", assistant: "out one"),
                LLMExample(user: "in two", assistant: "out two"),
            ],
            prompt: "the real input")
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(messages.map(\.content) == ["in one", "out one", "in two", "out two", "the real input"])
    }

    @Test func withoutExamplesThePromptIsTheOnlyMessage() {
        let messages = MLXBackend.chatMessages(examples: [], prompt: "just this")
        #expect(messages.map(\.role) == [.user])
        #expect(messages.map(\.content) == ["just this"])
    }
}
