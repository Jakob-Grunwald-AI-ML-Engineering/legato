import Foundation
import LegatoCore
import Testing
@testable import LegatoPostProcessing

/// The sentence-rewrite agent's prompt (spike #95, prompt v2): a checklist head, few-shot pairs, one sentence per
/// user turn, and the whole dictation with a closing request at stop.
@Suite struct CleanupAgentPromptTests {
    private let en = Locale(identifier: "en")

    private func head(_ style: CleanupStyle, emoji: MessageEmojiStyle = .off, itn: Bool = false) -> String {
        CleanupPrompt.Agent.instructions(locale: en, style: style, emoji: emoji, itn: itn)
    }

    @Test func theHeadAsksForTheCorrectedSentenceOnlyWithTheChecklist() {
        let text = head(.message)
        #expect(text.contains("reply with the corrected sentence only"))
        #expect(text.contains("homophones"))
        #expect(text.contains("self-correction"))
        #expect(text.contains("Each user turn is the next dictated sentence"))
        #expect(text.contains(CleanupPrompt.Agent.finalRequestLine))
        #expect(!text.contains("JSON"))
    }

    @Test func theSessionHeadIsTheInstructionsThenTheExamples() {
        let chunks = CleanupPrompt.Agent.sessionHead(locale: en, style: .message, emoji: .off)
        guard case .instructions(let text) = chunks.first else { Issue.record("no instructions first"); return }
        #expect(text == head(.message))
        let examples = chunks.dropFirst().compactMap { chunk -> LLMExample? in
            if case .example(let example) = chunk { return example }
            return nil
        }
        #expect(examples.count == chunks.count - 1)
        #expect(examples.count >= 8)
        // One sentence that needs nothing stays as it is.
        #expect(examples.contains { $0.user == $0.assistant })
        // Plain sentences in and out: no tags, labels or JSON.
        #expect(examples.allSatisfy { !$0.user.contains("<") && !$0.assistant.contains("{") })
    }

    @Test func eachStyleGetsItsOwnWritingRules() {
        #expect(head(.message).contains("ready-to-send"))
        #expect(head(.markdown).contains("Markdown"))
        #expect(head(.verbatim).contains("Keep the speaker's wording"))
        #expect(!head(.verbatim).contains("ready-to-send"))
        #expect(head(.verbatim, itn: true).contains("as digits"))
        #expect(!head(.verbatim).contains("as digits"))
    }

    @Test func automaticEmojiFollowTheMessageSettingOnly() {
        #expect(head(.message, emoji: .expressive).contains("expressive emoji"))
        #expect(head(.message).contains("Do not add automatic emoji"))
        #expect(head(.markdown, emoji: .expressive).contains("Do not add automatic emoji"))
        #expect(head(.verbatim, emoji: .subtle).contains("Do not add automatic emoji"))
    }

    /// Apple's dictation writes spoken filler as hashtags ("#um", "#ah", "#hm"): a style that removes filler
    /// removes those too; one that keeps the wording is not told to.
    @Test func fillerRemovingStylesDeleteHashtagFillerArtefacts() {
        let message = head(.message)
        #expect(message.contains("\"#um\"") && message.contains("\"#ah\"") && message.contains("\"#hm\""))
        #expect(!head(.verbatim).contains("#um"))
        // Verbatim's examples keep the filler.
        let verbatim = CleanupPrompt.Agent.examples(locale: en, style: .verbatim)
        #expect(verbatim.contains { $0.assistant.hasPrefix("Um,") })
        #expect(!CleanupPrompt.Agent.examples(locale: en, style: .message).contains { $0.assistant.hasPrefix("Um,") })
    }

    @Test func theLanguageRuleFollowsTheLocale() {
        #expect(CleanupPrompt.Agent.instructions(locale: Locale(identifier: "de"), style: .message).contains("Nie übersetzen"))
        #expect(head(.message).contains("Never translate"))
    }

    @Test func theFinalRequestFollowsTheWholeDictation() {
        let message = CleanupPrompt.Agent.finalRequest("one two. three")
        #expect(message.hasPrefix("one two. three\n\n"))
        #expect(message.hasSuffix(CleanupPrompt.Agent.finalRequestLine))
    }

    @Test func theSessionHeadDiffersByStyleAndEmojiOnly() {
        let a = CleanupPrompt.Agent.sessionHead(locale: en, style: .message, emoji: .off)
        #expect(a == CleanupPrompt.Agent.sessionHead(locale: en, style: .message, emoji: .off))
        #expect(a != CleanupPrompt.Agent.sessionHead(locale: en, style: .verbatim, emoji: .off))
        #expect(a != CleanupPrompt.Agent.sessionHead(locale: en, style: .message, emoji: .subtle))
    }

    @Test func statelessPromptIsUnchanged() {
        let instructions = CleanupPrompt.standard.instructions(en, [])
        #expect(!instructions.contains("corrected sentence only"))
        #expect(CleanupPrompt.standard.userMessage("x", en, []) == "<text>\nx\n</text>")
    }
}
