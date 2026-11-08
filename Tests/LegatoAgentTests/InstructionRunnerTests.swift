import Foundation
import Synchronization
import Testing
import LegatoClaude
import LegatoComposerDoc
@testable import LegatoAgent

/// Scripted replies, one per request: plain text, or a `read_more` call.
private final class ScriptedInstructionMessages: MessagesStreaming {
    enum Reply { case text(String), readMore }
    private let replies: Mutex<[Reply]>
    let requests = Mutex<[String]>([])
    init(_ replies: [Reply]) { self.replies = Mutex(replies) }

    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        requests.withLock { $0.append(String(decoding: request, as: UTF8.self)) }
        let reply = replies.withLock { $0.isEmpty ? Reply.text("") : $0.removeFirst() }
        return AsyncThrowingStream { continuation in
            func send(_ event: String, _ json: String) { continuation.yield(SSEEvent(event: event, data: json)) }
            switch reply {
            case .text(let text):
                send("content_block_start", #"{"index":0,"content_block":{"type":"text","text":""}}"#)
                // Small deltas, so the header is seen before the body arrives.
                var rest = Substring(text)
                while !rest.isEmpty {
                    let piece = String(rest.prefix(7)); rest = rest.dropFirst(7)
                    let encoded = String(decoding: try! JSONEncoder().encode(piece), as: UTF8.self)
                    send("content_block_delta", #"{"index":0,"delta":{"type":"text_delta","text":\#(encoded)}}"#)
                }
                send("content_block_stop", #"{"index":0}"#)
            case .readMore:
                send("content_block_start", #"{"index":0,"content_block":{"type":"tool_use","id":"t1","name":"read_more","input":{}}}"#)
                send("content_block_stop", #"{"index":0}"#)
            }
            send("message_stop", "{}")
            continuation.finish()
        }
    }
}

private let shortNote = InstructionContext(above: "Shopping list\nhey we need milk eggs and bread", below: "", sessionLength: 31)

@Suite struct InstructionReplyTests {
    @Test func parsesTheScopeHeaderAndTheBody() {
        #expect(InstructionReply.header("SCOPE: paragraph") == .scope(.paragraph))
        #expect(InstructionReply.header("scope:session") == .scope(.session))
        #expect(InstructionReply.header("**SCOPE:** All") == .scope(.all))
        #expect(InstructionReply.header("SCOPE: everything") == .unknown("everything"))
        #expect(InstructionReply.header("Here is the text:") == .malformed)
        let parsed = InstructionReply.parse("\nSCOPE: above\n```\nDear Anna,\nthanks.‸\n```\n")
        #expect(parsed.header == .scope(.above))
        #expect(parsed.body == "Dear Anna,\nthanks.")
        #expect(InstructionReply.parse("SCOPE: all\nWe ⟨meet|0.40⟩ at nine.").body == "We meet at nine.")
        let preamble = InstructionReply.parse("I will rewrite the paragraph.\nSCOPE: paragraph\nNew text.")
        #expect(preamble.header == .scope(.paragraph) && preamble.body == "New text.", "A sentence before the header is skipped")
        #expect(InstructionReply.parse("SCOPE: session").header == .scope(.session))
    }

    @Test func malformedOrUnknownScopesEditNothing() {
        #expect(throws: InstructionFailure.malformedReply) { try InstructionRunner.outcome(reply: "Sure! Here it is: Milk, eggs.", context: shortNote) }
        #expect(throws: InstructionFailure.unknownScope("document")) { try InstructionRunner.outcome(reply: "SCOPE: document\nMilk.", context: shortNote) }
        #expect(throws: InstructionFailure.unavailableScope(.selection)) { try InstructionRunner.outcome(reply: "SCOPE: selection\nMilk.", context: shortNote) }
        let emptyLine = InstructionContext(above: "Shopping list\n")
        #expect(throws: InstructionFailure.emptyText, "Nothing to delete in an empty paragraph") {
            try InstructionRunner.outcome(reply: "SCOPE: paragraph\n", context: emptyLine)
        }
        #expect(throws: InstructionFailure.unchanged) { try InstructionRunner.outcome(reply: "SCOPE: session\nhey we need milk eggs and bread", context: shortNote) }
        let selected = InstructionContext(above: "Intro ", below: " outro", selection: "the middle")
        #expect(throws: InstructionFailure.unavailableScope(.all)) { try InstructionRunner.outcome(reply: "SCOPE: all\nX", context: selected) }
    }
}

@Suite struct InstructionReplyGuardTests {
    let email = InstructionContext(above: "Hi Sam,\nthanks for the update on the harbour project.\nBest, Jo")

    @Test func anEmptyBodyDeletesTheScope() throws {
        for reply in ["SCOPE: all\n", "SCOPE: all", "SCOPE: all\n\n  \n"] {
            let outcome = try InstructionRunner.outcome(reply: reply, context: email)
            #expect(outcome.scope == .all && outcome.target == "" && outcome.range.text == email.above)
        }
        let session = try InstructionRunner.outcome(reply: "SCOPE: session\n", context: shortNote)
        #expect(session.target == "" && session.range.before == "hey we need milk eggs and bread")
    }

    @Test func aRemarkInsteadOfTextIsNotLanded() {
        for remark in ["(The field is emptied.)", "[deleted]", "*clears the text*"] {
            #expect(throws: InstructionFailure.commentary) { try InstructionRunner.outcome(reply: "SCOPE: all\n\(remark)", context: email) }
        }
        let aside = InstructionContext(above: "(call back later)")
        #expect((try? InstructionRunner.outcome(reply: "SCOPE: all\n(Call back later.)", context: aside))?.target == "(Call back later.)",
                "A field that is itself a remark may stay one")
        #expect((try? InstructionRunner.outcome(reply: "SCOPE: all\nHi Sam (and team),\nthanks.", context: email)) != nil)
    }

    @Test func anEmptyFieldHasNoTextToWorkOn() async {
        let messages = ScriptedInstructionMessages([])
        await #expect(throws: InstructionFailure.noText) {
            try await InstructionRunner(client: messages, model: { .haiku }).run(instruction: "make it formal", context: InstructionContext()) { _ in InstructionContext() }
        }
        #expect(messages.requests.withLock { $0.isEmpty }, "No model call for an empty field")
        #expect(!InstructionFailure.noText.canRetry && !InstructionFailure.unchanged.canRetry && InstructionFailure.overreach.canRetry)
    }

    static let threeParagraphs = InstructionContext(above: """
        Hi Sam, thanks for sending over the harbour survey results yesterday afternoon. The team reviewed them this morning and everything looks consistent with what we expected after the spring storms.
        The second point is about the budget: we would like to move the dredging work forward by roughly three weeks, because the contractor has availability in early March and waiting would push everything into the busy season, which nobody wants.
        Could you confirm by Friday whether the board agrees, so that we can sign the contract next week? Best regards, Jo
        """)

    @Test func aRewriteOfAnotherParagraphInTheCursorsPlaceIsRefused() {
        let concise = "The second point is about the budget: we would like to move the dredging work forward three weeks, while the contractor has availability in early March."
        #expect(throws: InstructionFailure.overreach) {
            try InstructionRunner.outcome(reply: "SCOPE: paragraph\n\(concise)", context: Self.threeParagraphs, instruction: "make the second paragraph more concise")
        }
    }

    @Test func aLocalInstructionMustKeepTheOtherParagraphs() throws {
        let lines = Self.threeParagraphs.above.components(separatedBy: "\n")
        let concise = "On the budget: we'd like to move the dredging forward three weeks, while the contractor is free in early March."
        let good = try InstructionRunner.outcome(reply: "SCOPE: all\n" + [lines[0], concise, lines[2]].joined(separator: "\n"),
                                                 context: Self.threeParagraphs, instruction: "make the second paragraph more concise")
        #expect(good.target.contains(concise) && good.target.hasPrefix(lines[0]))
        let everything = "Dear Sam,\nThank you for the survey.\nWe propose moving the dredging forward.\nPlease confirm by Friday.\nKind regards, Jo"
        #expect(throws: InstructionFailure.overreach) {
            try InstructionRunner.outcome(reply: "SCOPE: all\n" + everything, context: Self.threeParagraphs, instruction: "make the second paragraph more concise")
        }
        let formal = try InstructionRunner.outcome(reply: "SCOPE: all\n" + everything, context: Self.threeParagraphs, instruction: "make this more formal")
        #expect(formal.target == everything, "A whole-text rewrite lands")
        #expect(try InstructionRunner.outcome(reply: "SCOPE: all\n" + everything, context: Self.threeParagraphs,
                                              instruction: "make each paragraph shorter").target == everything)
    }
}

@Suite struct InstructionScopeTests {
    let context = InstructionContext(above: "Dear team,\n\nthe launch moved. we ship on friday", below: " if tests pass\nBest, Jo",
                                     sessionLength: 13, moreAbove: true, moreBelow: false, aboveFinal: false)

    @Test func scopesMapToTheTextAroundTheCursor() {
        #expect(InstructionScope.session.range(in: context) == .init(before: "ship on friday".suffix(13).description, after: ""))
        #expect(InstructionScope.paragraph.range(in: context) == .init(before: "the launch moved. we ship on friday", after: " if tests pass"))
        #expect(InstructionScope.above.range(in: context) == .init(before: context.above, after: ""))
        #expect(InstructionScope.all.range(in: context) == .init(before: context.above, after: context.below))
        #expect(InstructionScope.selection.range(in: context) == nil)
        let selected = InstructionContext(above: "a ", below: " c", selection: "b b")
        #expect(InstructionScope.selection.range(in: selected) == .init(before: "", after: "", selected: "b b"))
        #expect(InstructionScope.paragraph.range(in: selected) == nil, "With a selection only the selection is edited")
        #expect(InstructionScope.session.range(in: InstructionContext(above: "x")) == nil)
    }

    @Test func scopesLargerThanWhatWasShownAskForARead() {
        #expect(InstructionScope.all.read(for: context) == .toCap)
        #expect(InstructionScope.above.read(for: context) == .toCap)
        #expect(InstructionScope.paragraph.read(for: context) == nil, "The paragraph's start was shown")
        #expect(InstructionScope.paragraph.read(for: InstructionContext(above: "no line break here", moreAbove: true, aboveFinal: false)) == .block)
        #expect(InstructionScope.session.read(for: context) == nil)
        var final = context; final.aboveFinal = true
        #expect(InstructionScope.all.read(for: final) == nil, "Nothing more is read past a stop or the cap")
    }

    @Test func allIsNeverLandedOverTextThatWasNotRead() {
        // The cursor at the start: only the host's window below it is known.
        let start = InstructionContext(above: "", below: "Hi Sam,\nthe survey is in.", moreBelow: true)
        #expect(InstructionScope.all.read(for: start) == .toCap)
        #expect(InstructionScope.paragraph.read(for: start) == nil, "The paragraph's end was shown")
        #expect(throws: InstructionFailure.partialScope(.all)) { try InstructionRunner.outcome(reply: "SCOPE: all\nDear Sam,\nthe survey is in.", context: start) }
        // Read to the cap on one side: still partial.
        let capped = InstructionContext(above: "…the end", below: "", moreAbove: true, aboveFinal: true, aboveComplete: false)
        #expect(InstructionScope.all.read(for: capped) == nil)
        #expect(throws: InstructionFailure.partialScope(.all)) { try InstructionRunner.outcome(reply: "SCOPE: all\n", context: capped) }
        #expect(throws: InstructionFailure.partialScope(.above)) { try InstructionRunner.outcome(reply: "SCOPE: above\nThe end.", context: capped) }
        #expect((try? InstructionRunner.outcome(reply: "SCOPE: paragraph\n…The end.", context: capped)) != nil, "The cursor's paragraph was shown")
        // A quote or a signature ends the user's text: that is complete.
        let quoted = InstructionContext(above: "Sounds good", below: "\n\nOn Mon, Anna wrote:", moreBelow: true, belowFinal: true, belowComplete: true)
        #expect((try? InstructionRunner.outcome(reply: "SCOPE: all\nSounds good!", context: quoted)) != nil)
    }

    @Test func theTargetKeepsTheScopesSurroundingWhitespace() {
        let range = InstructionScopeRange(before: " we ship on friday\n", after: "")
        #expect(range.target(for: "\nWe ship on Friday.\n") == " We ship on Friday.\n")
    }

    @Test func confidenceMarksGoOnUnsureWords() {
        let words = [Word(text: "make", confidence: 0.98), Word(text: "this", confidence: 0.42), Word(text: "formal")]
        #expect(InstructionRunner.present(words) == "make ⟨this|0.42⟩ formal")
    }
}

@Suite(.timeLimit(.minutes(1))) struct InstructionRunTests {
    @Test func plainReplyBecomesTheScopesReplacement() async throws {
        let messages = ScriptedInstructionMessages([.text("SCOPE: session\nWe need milk, eggs and bread.")])
        let runner = InstructionRunner(client: messages, model: { .haiku })
        let outcome = try await runner.run(instruction: "make this a proper sentence", context: shortNote) { _ in
            Issue.record("No read was needed"); return shortNote
        }
        #expect(outcome.scope == .session)
        #expect(outcome.target == "We need milk, eggs and bread.")
        let request = try #require(messages.requests.withLock { $0.first })
        #expect(request.contains("claude-haiku-5-5"))
        #expect(!request.contains("\"tools\""), "Nothing to read: the tool is not offered")
    }

    @Test func readMoreExtendsTheContextThenTheReplyLands() async throws {
        let start = InstructionContext(above: "Thanks for the call.", sessionLength: 20, moreAbove: true, aboveFinal: false)
        let grown = InstructionContext(above: "Hi Max,\n\nThanks for the call.", sessionLength: 20, moreAbove: false, aboveFinal: true)
        let messages = ScriptedInstructionMessages([.readMore, .text("SCOPE: all\nHi Max,\n\nThank you for the call.")])
        let reads = Mutex<[InstructionRead]>([])
        let outcome = try await InstructionRunner(client: messages, model: { .haiku })
            .run(instruction: "fix the whole message", context: start) { kind in reads.withLock { $0.append(kind) }; return grown }
        #expect(reads.withLock { $0 } == [.block])
        #expect(outcome.range == .init(before: grown.above, after: ""))
        #expect(outcome.target == "Hi Max,\n\nThank you for the call.")
        let second = try #require(messages.requests.withLock { $0.last })
        #expect(second.contains("tool_result") && second.contains("more_remains"))
    }

    @Test func aScopeBiggerThanWhatWasShownReadsToTheCapAndAsksAgain() async throws {
        let start = InstructionContext(above: "and see you then", sessionLength: 16, moreAbove: true, aboveFinal: false)
        let full = InstructionContext(above: "Hello Anna,\nthe meeting moved to Thursday\nand see you then", sessionLength: 16,
                                      moreAbove: false, aboveFinal: true)
        let messages = ScriptedInstructionMessages([.text("SCOPE: all\nHello"), .text("SCOPE: all\nHello Anna,\nthe meeting moved to Thursday.\nSee you then.")])
        let reads = Mutex<[InstructionRead]>([])
        let outcome = try await InstructionRunner(client: messages, model: { .haiku })
            .run(instruction: "make the whole thing tidy", context: start) { kind in reads.withLock { $0.append(kind) }; return full }
        #expect(reads.withLock { $0 } == [.toCap])
        #expect(outcome.range.before == full.above)
        #expect(outcome.target.hasSuffix("See you then."))
        #expect(messages.requests.withLock { $0.count } == 2)
        #expect(messages.requests.withLock { $0[1] }.contains("the meeting moved to Thursday"))
    }

    @Test func theCursorAtTheStartReadsDownBeforeAllLands() async throws {
        let start = InstructionContext(above: "", below: "Hi Sam,\n", moreBelow: true)
        let full = InstructionContext(above: "", below: "Hi Sam,\nthe survey is in.\nBest, Jo", moreBelow: false, belowFinal: true)
        let messages = ScriptedInstructionMessages([.text("SCOPE: all\nDear Sam,"), .text("SCOPE: all\nDear Sam,\nthe survey has arrived.\nBest, Jo")])
        let reads = Mutex<[InstructionRead]>([])
        let outcome = try await InstructionRunner(client: messages, model: { .haiku })
            .run(instruction: "make the second line more formal", context: start) { kind in reads.withLock { $0.append(kind) }; return full }
        #expect(reads.withLock { $0 } == [.toCap])
        #expect(outcome.range.after == full.below && outcome.target.contains("has arrived"))
        #expect(messages.requests.withLock { $0[0] }.contains("[text continues below, not read]"))
    }

    @Test func aDeletionWithOnlyAHeaderStillReadsFirst() async throws {
        let start = InstructionContext(above: "", below: "Hi Sam,\n", moreBelow: true)
        let full = InstructionContext(above: "", below: "Hi Sam,\nthe survey is in.", moreBelow: false)
        let messages = ScriptedInstructionMessages([.text("SCOPE: all"), .text("SCOPE: all")])
        let outcome = try await InstructionRunner(client: messages, model: { .haiku })
            .run(instruction: "delete everything", context: start) { _ in full }
        #expect(outcome.target == "" && outcome.range.after == full.below && outcome.reads == 1)
    }

    @Test func eachModelGetsTheThinkingAndToolChoiceItAccepts() throws {
        func request(_ model: ModelChoice) throws -> [String: Any] {
            let data = try InstructionRunner.request(model: model, system: "s", messages: [], tools: true)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func thinking(_ r: [String: Any]) -> String? { (r["thinking"] as? [String: Any])?["type"] as? String }
        func choice(_ r: [String: Any]) -> String? { (r["tool_choice"] as? [String: Any])?["type"] as? String }
        let haiku = try request(.haiku), sonnet = try request(.sonnet), opus = try request(.opus)
        #expect(thinking(haiku) == "disabled" && haiku["output_config"] == nil)
        #expect(thinking(sonnet) == "between_tools", "Sonnet 5.5 rejects thinking: disabled")
        #expect(thinking(opus) == "adaptive")
        for r in [haiku, sonnet, opus] { #expect(choice(r) == "auto", "No model is forced to call read_more") }
        #expect((sonnet["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func aFailedReadIsAToolErrorNotPartialText() async throws {
        let start = InstructionContext(above: "Last line.", sessionLength: 10, moreAbove: true, aboveFinal: false)
        let messages = ScriptedInstructionMessages([.readMore, .text("SCOPE: session\nThe last line.")])
        let outcome = try await InstructionRunner(client: messages, model: { .haiku })
            .run(instruction: "capitalize", context: start) { _ in throw InstructionFailure.read("This app's text could not be read reliably.") }
        #expect(outcome.target == "The last line.")
        let second = try #require(messages.requests.withLock { $0.last })
        #expect(second.contains("\"is_error\":true") && second.contains("Read failed"))
    }
}
