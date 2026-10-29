import Foundation
import LegatoCore
import MLXLMCommon
import Synchronization
import Testing
@testable import LegatoMLX

/// A word-level "model": one token per word (ids from a shared vocabulary), the cache a token list, and a
/// scripted reply it predicts token by token whatever the prompt.
private final class FakeForward: MLXTokenForwarding, @unchecked Sendable {
    struct State { var cache: [Int] = []; var fed: [[Int]] = []; var predicted: [[Int]] = []; var rewinds: [Int] = [] }
    let state = Mutex(State())
    let reply: [Int]
    let eos: Int
    init(reply: [Int], eos: Int) { self.reply = reply; self.eos = eos }

    func feed(_ tokens: [Int], device: ComputeDevice) async throws {
        state.withLock { $0.cache += tokens; $0.fed.append(tokens) }
    }
    func predict(_ tokens: [Int], device: ComputeDevice) async throws -> [Int] {
        state.withLock { s in
            s.cache += tokens; s.predicted.append(tokens)
            // The reply position after each input: how many reply tokens precede it in the cache's tail.
            return tokens.indices.map { i in
                let produced = Self.producedCount(s.cache.prefix(s.cache.count - tokens.count + i + 1), reply: reply)
                return produced < reply.count ? reply[produced] : eos
            }
        }
    }
    /// How much of `reply` the cache already ends with, after the last prompt marker (id 0).
    static func producedCount(_ cache: ArraySlice<Int>, reply: [Int]) -> Int {
        guard let marker = cache.lastIndex(of: 0) else { return 0 }
        let tail = Array(cache[(marker + 1)...])
        var n = 0
        while n < tail.count, n < reply.count, tail[n] == reply[n] { n += 1 }
        return n
    }
    func rewind(_ count: Int) async throws { state.withLock { $0.cache.removeLast(count); $0.rewinds.append(count) } }
    func reset() async { state.withLock { $0.cache = [] } }
}

private final class Vocabulary: @unchecked Sendable {
    private let ids = Mutex<[String: Int]>(["<gen>": 0, "<eos>": 1])
    func id(_ word: String) -> Int { ids.withLock { map in map[word] ?? { map[word] = map.count; return map.count - 1 }() } }
    func word(_ id: Int) -> String { ids.withLock { map in map.first { $0.value == id }?.key ?? "?" } }
    func encode(_ text: String) -> [Int] { text.split(whereSeparator: \.isWhitespace).map { id(String($0)) } }
    /// role marker, content words, end marker per message; the generation marker (0) last.
    func render(_ messages: [MLXIncrementalChat.Message]) -> [Int] {
        messages.flatMap { [id("<\($0.role)>")] + encode($0.content) + [id("</m>")] } + [0]
    }
}

private func makeChat(reply: String, draft: Bool) -> (MLXIncrementalChat, FakeForward, Vocabulary) {
    let vocabulary = Vocabulary()
    let forward = FakeForward(reply: vocabulary.encode(reply), eos: 1)
    let chat = MLXIncrementalChat(
        render: { vocabulary.render($0) }, encode: { vocabulary.encode($0) },
        decode: { $0.map { vocabulary.word($0) }.joined(separator: " ") },
        forward: forward, eos: [1], options: .init(draft: draft, draftNgram: 1, draftLength: 4, maxTokens: 50))
    chat.setHistory(instructions: "fix it", history: [])
    return (chat, forward, vocabulary)
}

private func reply(_ chat: MLXIncrementalChat, _ message: String) async throws -> (text: String, stats: MLXTurnStats?) {
    var text = "", stats: MLXTurnStats?
    for try await event in chat.stream(message, device: .cpu) {
        switch event {
        case .chunk(let chunk): text += chunk
        case .info(let info): stats = info
        }
    }
    return (text, stats)
}

@Suite struct MLXTokensTests {
    @Test func promptLookupCopiesWhatFollowedTheLastMatch() {
        #expect(MLXTokens.lookup([5, 6, 7, 8, 9, 5, 6], ngram: 2, length: 2) == [7, 8])
        #expect(MLXTokens.lookup([5, 6, 7], ngram: 2, length: 3) == [])
        #expect(MLXTokens.accepted(draft: [7, 8, 9], predictions: [7, 8, 4, 2]) == 2)
        #expect(MLXTokens.accepted(draft: [], predictions: [3]) == 0)
        #expect(MLXTokens.commonPrefix([1, 2, 3], [1, 2, 4]) == 2)
    }
}

@Suite struct MLXIncrementalChatTests {
    @Test func aPrefilledMessageIsNotFedAgainAtTheRequest() async throws {
        let (chat, forward, _) = makeChat(reply: "Send the report now.", draft: false)
        let ahead = try await chat.prefill(partial: "send teh", device: .cpu)
        // <system> fix it </m> <user> send teh: what a longer message would still start with.
        #expect(ahead == 7)
        let (text, stats) = try await reply(chat, "send teh report now.")
        #expect(text == "Send the report now.")
        #expect(stats?.cached == 7)
        #expect(stats?.prefilled == 4)  // "report now. </m>" and the generation marker
        #expect(forward.state.withLock { $0.rewinds }.isEmpty)
    }

    @Test func theNextTurnReusesTheConversationAndRewindsWhatChanged() async throws {
        let (chat, forward, _) = makeChat(reply: "Fixed.", draft: false)
        _ = try await reply(chat, "one two")
        // A rebuilt history (an older turn dropped) differs after the system message: rolled back, fed again.
        chat.setHistory(instructions: "fix it", history: [])
        let (_, stats) = try await reply(chat, "three")
        #expect(stats?.cached == 5)  // the system message and the user marker
        #expect(forward.state.withLock { $0.rewinds }.count == 1)
    }

    @Test func promptLookupAcceptsCopiedTokensAndRewindsTheRest() async throws {
        let (plain, _, _) = makeChat(reply: "send the report now please", draft: false)
        let (drafted, forward, _) = makeChat(reply: "send the report now please", draft: true)
        let expected = try await reply(plain, "send teh report now please").text
        let (text, _) = try await reply(drafted, "send teh report now please")
        #expect(text == expected)
        let stats = drafted.lastDraft
        #expect(stats.accepted > 0)
        #expect(stats.forwards < 6)  // fewer passes than one per token (5 words + end)
        #expect(stats.proposed >= stats.accepted)
        _ = forward
    }
}

@Suite struct ProbePassageMergeTests {
    @Test func onlyTheDriftingSentenceIsTurnedDown() {
        let corpus = [
            ProbeSentence(id: "A", passage: "p", tags: [], text: "send teh report.", reference: "Send the report.",
                          mistakes: [ProbeMistake(wrong: "teh", fixes: ["the"], kind: .local, type: "spelling")]),
            ProbeSentence(id: "B", passage: "p", tags: [], text: "Das ist gut so.", reference: "Das ist gut so.", mistakes: []),
        ]
        var document = ProbeRewriteDocument(sentences: corpus)
        for chunk in ProbeChunker.chunks(sentences: corpus, wordsPerSecond: 10, seed: 1, minWords: 7, maxWords: 7) { document.receive(chunk) }
        let (outcome, rejected) = ProbeRewriteMerge.mergePerSentence("Send the report. That is fine like this.", into: &document, range: 0..<7)
        #expect(rejected == 1)
        #expect(document.sentenceText(0) == "Send the report.")
        #expect(document.sentenceText(1) == "Das ist gut so.")
        #expect(outcome.changed.map(\.sentence) == [0])
    }
}
