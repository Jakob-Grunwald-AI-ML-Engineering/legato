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
        #expect(throws: InstructionFailure.emptyText) { try InstructionRunner.outcome(reply: "SCOPE: session\n  \n", context: shortNote) }
        #expect(throws: InstructionFailure.unchanged) { try InstructionRunner.outcome(reply: "SCOPE: session\nhey we need milk eggs and bread", context: shortNote) }
        let selected = InstructionContext(above: "Intro ", below: " outro", selection: "the middle")
        #expect(throws: InstructionFailure.unavailableScope(.all)) { try InstructionRunner.outcome(reply: "SCOPE: all\nX", context: selected) }
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
                                      moreAbove: true, aboveFinal: true)
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
