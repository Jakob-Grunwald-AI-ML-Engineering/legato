import Foundation
import LegatoCore
import MLX
import MLXLMCommon

// Spike #95: an MLX chat that owns its KV cache, so a session can prefill an unfinished user message ahead of
// the endpoint (mlx-swift-lm's `ChatSession` prefills only together with a generation) and can decode with
// prompt lookup (draft tokens copied from the prompt, verified several per forward pass).
//
// Every turn renders the whole conversation with the chat template and reuses the longest common token prefix
// with what the cache holds; anything past it is rolled back (trimmed) and fed again. So a trimmed history, a
// re-rendered assistant turn or a changed word costs only the tokens after the first difference.

/// The model and its KV cache: the seam the engine tests replace.
protocol MLXTokenForwarding: AnyObject, Sendable {
    /// Appends `tokens` to the cache; reads no logits.
    func feed(_ tokens: [Int], device: ComputeDevice) async throws
    /// Appends `tokens` and returns the greedy next token after each of them.
    func predict(_ tokens: [Int], device: ComputeDevice) async throws -> [Int]
    /// Drops the last `count` positions of the cache.
    func rewind(_ count: Int) async throws
    /// Forgets the cache (the next feed starts from an empty one).
    func reset() async
}

/// How a turn decoded, for the probe.
struct MLXDraftStats: Sendable, Equatable {
    var proposed = 0
    var accepted = 0
    var forwards = 0
}

enum MLXTokens {
    static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var n = 0
        while n < min(a.count, b.count), a[n] == b[n] { n += 1 }
        return n
    }

    /// Prompt lookup: the tokens that followed the most recent earlier occurrence of the last `ngram` tokens of
    /// `sequence`, at most `length` of them; empty when the tail occurs nowhere else.
    static func lookup(_ sequence: [Int], ngram: Int, length: Int) -> [Int] {
        guard ngram > 0, length > 0, sequence.count > ngram else { return [] }
        let tail = Array(sequence.suffix(ngram))
        var start = sequence.count - ngram - 1
        while start >= 0 {
            if Array(sequence[start..<(start + ngram)]) == tail {
                let from = start + ngram
                return Array(sequence[from..<min(sequence.count, from + length)])
            }
            start -= 1
        }
        return []
    }

    /// How many of `draft` the model confirmed: `predictions[i]` is its token after input `i` (the last real
    /// token, then the drafts), so draft `i` stands while it equals `predictions[i]`.
    static func accepted(draft: [Int], predictions: [Int]) -> Int {
        var n = 0
        while n < draft.count, n < predictions.count, draft[n] == predictions[n] { n += 1 }
        return n
    }
}

/// A chat over one KV cache that this object owns (see the file comment).
final class MLXIncrementalChat: MLXChatTurning, @unchecked Sendable {
    struct Options: Sendable, Equatable {
        /// Decode with prompt lookup.
        var draft = false
        var draftNgram = 2
        var draftLength = 10
        var maxTokens = MLXBackend.replyLimit
    }

    typealias Message = (role: String, content: String)

    private let render: @Sendable ([Message]) throws -> [Int]
    private let encode: @Sendable (String) -> [Int]
    private let decode: @Sendable ([Int]) -> String
    private let forward: any MLXTokenForwarding
    private let eos: Set<Int>
    let options: Options
    private let lock = NSLock()
    private var messages: [Message] = []
    /// The tokens the cache holds.
    private var fed: [Int] = []
    private(set) var lastDraft = MLXDraftStats()

    init(render: @escaping @Sendable ([Message]) throws -> [Int], encode: @escaping @Sendable (String) -> [Int],
         decode: @escaping @Sendable ([Int]) -> String, forward: any MLXTokenForwarding, eos: Set<Int>, options: Options) {
        self.render = render; self.encode = encode; self.decode = decode; self.forward = forward; self.eos = eos
        self.options = options
    }

    /// The conversation before the next turn: the instructions, then `history` (examples and kept turns). The
    /// cache is kept; the next turn reuses whatever prefix still matches.
    func setHistory(instructions: String, history: [Chat.Message]) {
        let head: [Message] = instructions.isEmpty ? [] : [("system", instructions)]
        let rest: [Message] = history.map { ($0.role == .assistant ? "assistant" : "user", $0.content) }
        lock.withLock { messages = head + rest }
    }

    func tokenCount(_ text: String) async -> Int { encode(text).count }

    /// Prefills the part of an unfinished user message `partial` whose tokens can no longer change (what
    /// follows may still merge with its last token), without generating. Returns the tokens fed.
    func prefill(partial: String, device: ComputeDevice) async throws -> Int {
        let base = lock.withLock { messages }
        let now = try render(base + [("user", partial)])
        let longer = try render(base + [("user", partial + " x")])
        let stable = Array(now.prefix(MLXTokens.commonPrefix(now, longer)))
        return try await sync(to: stable, device: device)
    }

    /// Makes the cache hold exactly `target` (reusing the common prefix). Returns the tokens fed.
    @discardableResult
    private func sync(to target: [Int], device: ComputeDevice) async throws -> Int {
        let held = lock.withLock { fed }
        let keep = MLXTokens.commonPrefix(held, target)
        if held.count > keep {
            try await forward.rewind(held.count - keep)
            lock.withLock { fed.removeLast(held.count - keep) }
        }
        let rest = Array(target[keep...])
        guard !rest.isEmpty else { return 0 }
        do {
            try await forward.feed(rest, device: device)
        } catch {
            await invalidate()
            throw error
        }
        lock.withLock { fed += rest }
        return rest.count
    }

    /// After an error the cache's contents are unknown: start over.
    func invalidate() async {
        await forward.reset()
        lock.withLock { fed = [] }
    }

    func stream(_ message: String, device: ComputeDevice) -> AsyncThrowingStream<MLXTurnEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.turn(message, device: device) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    await self.invalidate()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func turn(_ message: String, device: ComputeDevice, yield: (MLXTurnEvent) -> Void) async throws {
        let base = lock.withLock { messages }
        let prompt = try render(base + [("user", message)])
        guard let last = prompt.last else { throw LLMError.emptyResponse }
        let started = ContinuousClock.now
        let held = lock.withLock { fed }
        let cached = min(MLXTokens.commonPrefix(held, prompt), prompt.count - 1)
        try await sync(to: Array(prompt.dropLast()), device: device)
        let prefillDone = ContinuousClock.now
        var stats = MLXDraftStats()
        var output: [Int] = []
        var shown = ""
        var input = last
        var finished = false
        while !finished, output.count < options.maxTokens {
            try Task.checkCancellation()
            let draft = options.draft
                ? Array(MLXTokens.lookup(prompt + output, ngram: options.draftNgram, length: options.draftLength)
                    .prefix(options.maxTokens - output.count - 1))
                : []
            let predictions = try await forward.predict([input] + draft, device: device)
            stats.forwards += 1
            lock.withLock { fed += [input] + draft }
            let accepted = MLXTokens.accepted(draft: draft, predictions: predictions)
            stats.proposed += draft.count; stats.accepted += accepted
            if draft.count > accepted {
                try await forward.rewind(draft.count - accepted)
                lock.withLock { fed.removeLast(draft.count - accepted) }
            }
            for token in predictions.prefix(accepted + 1) {
                if eos.contains(token) || output.count >= options.maxTokens { finished = true; break }
                output.append(token)
            }
            if !finished, let next = output.last { input = next }
            let text = decode(output)
            if text.count > shown.count, text.hasPrefix(shown) {
                yield(.chunk(String(text.dropFirst(shown.count))))
                shown = text
            }
            if output.isEmpty { finished = true }
        }
        // The last generated token is not in the cache yet; the next turn feeds what its render needs.
        let reply = decode(output)
        if reply.count > shown.count, reply.hasPrefix(shown) { yield(.chunk(String(reply.dropFirst(shown.count)))) }
        lock.withLock {
            messages += [("user", message), ("assistant", reply)]
            lastDraft = stats
        }
        let prefill = prefillDone - started
        yield(.info(MLXTurnStats(prefilled: prompt.count - cached, cached: cached,
                                 prefillSeconds: Double(prefill.components.seconds) + Double(prefill.components.attoseconds) / 1e18)))
    }
}

// MARK: - The real model

#if canImport(Cmlx)  // the real MLX; the CI stub has no arrays or models
    /// The container's model over a KV cache this object owns. Each call runs on `device` (the CPU as the
    /// task's default device, compile off where needed) and turns MLX errors into thrown ones.
    final class MLXModelForward: MLXTokenForwarding, @unchecked Sendable {
        private let container: ModelContainer
        private var cache: [KVCache]?
        /// Tokens per forward pass while feeding (mlx-swift-lm's prefill step).
        private let step = 512

        init(container: ModelContainer) { self.container = container }

        private func run<R: Sendable>(_ device: ComputeDevice, _ body: @escaping @Sendable (any LanguageModel, [KVCache]) throws -> R) async throws -> R {
            MLXCompile.prepare(for: device)
            let work: @Sendable () async throws -> R = { [self] in
                try await container.perform { (context: ModelContext) in
                    let model = context.model
                    if self.cache == nil { self.cache = try model.newCache(parameters: nil) }
                    let cache = self.cache!
                    return try MLX.withError { try body(model, cache) }
                }
            }
            switch device {
            case .gpu: return try await work()
            case .cpu: return try await Device.withDefaultDevice(.cpu) { try await work() }
            }
        }

        func feed(_ tokens: [Int], device: ComputeDevice) async throws {
            let step = step
            try await run(device) { model, cache in
                var start = 0
                while start < tokens.count {
                    let chunk = tokens[start..<min(tokens.count, start + step)].map { Int32($0) }
                    _ = model(MLXArray(chunk)[.newAxis], cache: cache)
                    eval(cache)
                    start += step
                }
            }
        }

        func predict(_ tokens: [Int], device: ComputeDevice) async throws -> [Int] {
            try await run(device) { model, cache in
                let logits = model(MLXArray(tokens.map { Int32($0) })[.newAxis], cache: cache)
                let next = argMax(logits[0], axis: -1)
                eval(next)
                return next.asArray(Int32.self).map(Int.init)
            }
        }

        func rewind(_ count: Int) async throws {
            guard count > 0, let cache else { return }
            for layer in cache { layer.trim(count) }
        }

        func reset() async { cache = nil }
    }

    extension MLXIncrementalChat {
        /// Over the cached container's model and tokenizer, Qwen3's thinking off.
        static func make(container: ModelContainer, spec: MLXModelSpec, options: Options) async -> MLXIncrementalChat {
            let tokenizer = await container.tokenizer
            var eos = Set<Int>()
            for token in [tokenizer.eosToken, "<|im_end|>", "<|endoftext|>"].compactMap({ $0 }) + Array(spec.extraEOSTokens) {
                if let id = tokenizer.convertTokenToId(token) { eos.insert(id) }
            }
            return MLXIncrementalChat(
                render: { messages in
                    try tokenizer.applyChatTemplate(
                        messages: messages.map { ["role": $0.role, "content": $0.content] as [String: any Sendable] },
                        tools: nil, additionalContext: ["enable_thinking": false])
                },
                encode: { tokenizer.encode(text: $0, addSpecialTokens: false) },
                decode: { tokenizer.decode(tokenIds: $0, skipSpecialTokens: true) },
                forward: MLXModelForward(container: container), eos: eos, options: options)
        }
    }
#endif
