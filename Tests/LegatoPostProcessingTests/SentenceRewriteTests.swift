import Foundation
import LegatoCore
import Testing
@testable import LegatoPostProcessing

/// The pieces around the sentence-rewrite agent's model turn: when a sentence is ready, what of the reply is the
/// sentence, which rewrites are let through, and how much context a turn may hold.
struct SentenceRewriteTests {
    // MARK: Endpointing

    @Test(arguments: [
        ("We fly on Monday.", true), ("Really?", true), ("Wow!", true), ("Well…", true), ("He said \"go.\"", true),
        ("(See above.)", true), ("Ask Dr.", false), ("for example e.g.", false), ("and then we", false), ("", false),
        ("The cost is 3.", true), ("Meet Mr.", false),
    ])
    func aSentenceEndsWithTerminalPunctuationButNotATitle(text: String, ends: Bool) {
        #expect(SentenceEndpointer.endsSentence(text) == ends)
    }

    @Test func aSentenceFollowedByMoreTextIsReady() {
        let endpointer = SentenceEndpointer()
        #expect(endpointer.ready("and then we", isLast: false, quiet: .zero, final: false) == .followed)
    }

    @Test func theLastSentenceIsReadyAtItsFullStop() {
        let endpointer = SentenceEndpointer()
        #expect(endpointer.ready("We fly on Monday.", isLast: true, quiet: .zero, final: false) == .punctuation)
        #expect(endpointer.ready("We fly on", isLast: true, quiet: .zero, final: false) == nil)
    }

    @Test func aPauseEndsAnUnpunctuatedSentence() {
        let endpointer = SentenceEndpointer(config: .init(pause: .milliseconds(700), maxWords: 30))
        #expect(endpointer.ready("we fly on monday", isLast: true, quiet: .milliseconds(699), final: false) == nil)
        #expect(endpointer.ready("we fly on monday", isLast: true, quiet: .milliseconds(700), final: false) == .pause)
    }

    @Test func aRunOnIsCutAtTheWordLimit() {
        let endpointer = SentenceEndpointer(config: .init(pause: .seconds(5), maxWords: 5))
        #expect(endpointer.ready("one two three four", isLast: true, quiet: .zero, final: false) == nil)
        #expect(endpointer.ready("one two three four five", isLast: true, quiet: .zero, final: false) == .length)
    }

    @Test func atStopTheUnfinishedSentenceIsReady() {
        let endpointer = SentenceEndpointer()
        #expect(endpointer.ready("and then we", isLast: true, quiet: .zero, final: true) == .end)
        #expect(endpointer.ready("   ", isLast: true, quiet: .zero, final: true) == nil)
    }

    // MARK: Reply

    @Test func theReplyLosesThinkBlocksLabelsAndWrappingQuotes() {
        #expect(RewriteReply.clean("<think>hmm</think>\nAssistant: \"We fly on Monday.\"") == "We fly on Monday.")
        #expect(RewriteReply.clean("Sentence: Hello.") == "Hello.")
        #expect(RewriteReply.clean("  \n ") == nil)
        #expect(RewriteReply.clean("<think>unfinished") == nil)
    }

    @Test func lineBreaksAreJoinedUnlessTheStyleKeepsThem() {
        #expect(RewriteReply.clean("Buy milk.\nCall Anna.") == "Buy milk. Call Anna.")
        #expect(RewriteReply.clean("- Buy milk\n- Call Anna", keepLineBreaks: true) == "- Buy milk\n- Call Anna")
    }

    // MARK: Guard

    @Test func fixesFillerRemovalAndWrittenFormsAreLetThrough() {
        let pairs: [(String, String)] = [
            ("I can't decide weather to take the train.", "I can't decide whether to take the train."),
            ("Um, that sounds good.", "That sounds good."),
            ("Book a table for six, no wait, seven people.", "Book a table for seven people."),
            ("Open x code and fix the four oh four page.", "Open Xcode and fix the 404 page."),
            ("we fly to paris on monday.", "We fly to Paris on Monday."),
        ]
        for (reference, candidate) in pairs {
            #expect(RewriteGuard.accepts(candidate, reference: reference), "\(reference) -> \(candidate)")
        }
    }

    @Test func anAnswerATranslationOrADifferentTextIsRejected() {
        let reference = "What time does the ferry leave on Sunday?"
        #expect(!RewriteGuard.accepts("The ferry leaves at 10 AM on Sundays, according to the timetable.", reference: reference))
        #expect(!RewriteGuard.accepts("Wann fährt die Fähre am Sonntag ab?", reference: reference))
        #expect(!RewriteGuard.accepts("", reference: reference))
    }

    // MARK: Context budget

    @Test func theTurnBudgetIsAShareOfTheBackendsBudget() {
        #expect(RewriteContext.budget(tokenBudget: 2_000) == 1_000)
        #expect(RewriteContext.budget(tokenBudget: 2_000, share: 25) == 500)
    }

    @Test func aTurnThatFitsTrimsNothing() {
        let usage = LLMTokenUsage(head: 300, history: 200)
        #expect(RewriteContext.trimTarget(usage: usage, request: 20, budget: 1_000) == nil)
    }

    @Test func aTurnThatWouldPassTheShareTrimsTheHistoryKeepingTheHeadAndRecentTurns() throws {
        let usage = LLMTokenUsage(head: 300, history: 700)
        let request = 20
        let keep = try #require(RewriteContext.trimTarget(usage: usage, request: request, budget: 1_000))
        // What stays (head + kept history + the request + its reply) is within the budget.
        #expect(usage.head + keep + request + RewriteContext.replyReserve(requestTokens: request) <= 1_000)
        #expect(keep > 0)
    }

    @Test func aHeadLargerThanTheShareDropsAllHistory() {
        let usage = LLMTokenUsage(head: 1_200, history: 50)
        #expect(RewriteContext.trimTarget(usage: usage, request: 20, budget: 1_000) == 0)
    }
}
