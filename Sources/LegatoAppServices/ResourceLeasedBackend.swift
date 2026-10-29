import LegatoCore

/// Pins already-prepared resources through a cleanup response; response admission never cold-loads.
///
/// A session made here pins them for its whole length: ``makeSession()`` acquires the lease once and the
/// session releases it when it closes or is dropped. Releasing the resources (memory pressure, model change)
/// ends it through the backend. Cleanup runs use the warmup's rolling session instead
/// (``SelectedModelWarmup/rollingSession(key:)``), which lives with the prepared resource.
struct ResourceLeasedBackend: LLMBackend {
    let backend: any LLMBackend
    let owner: SelectedModelWarmup
    let key: String
    var id: String { backend.id }
    var maxPromptCharacters: Int? { backend.maxPromptCharacters }
    var availability: LLMAvailability { get async { await backend.availability } }
    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        let lease = try await acquire()
        do {
            let result = try await backend.respond(instructions: instructions, examples: examples, prompt: prompt)
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }
    func makeSession() async throws -> any LLMSession {
        let lease = try await acquire()
        let inner: any LLMSession
        do { inner = try await backend.makeSession() } catch { await lease.release(); throw error }
        return LeasedLLMSession(inner: inner, lease: lease)
    }
    private func acquire() async throws -> SelectedModelWarmup.Lease {
        do { return try await owner.acquire(keys: [key], inBackground: true) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LLMError.unavailable(reason: "Prepare the selected model in Legato before cleanup.") }
    }
}

/// A session that holds its resource lease until it closes, or until it is dropped without closing.
actor LeasedLLMSession: LLMSession {
    nonisolated let tokenBudget: Int
    private let inner: any LLMSession
    private var lease: SelectedModelWarmup.Lease?

    init(inner: any LLMSession, lease: SelectedModelWarmup.Lease) {
        self.inner = inner; self.lease = lease; self.tokenBudget = inner.tokenBudget
    }

    func usage() async throws -> LLMTokenUsage { try open(); return try await inner.usage() }
    func append(_ chunk: LLMSessionChunk) async throws { try open(); try await inner.append(chunk) }
    func respond(to request: String) async throws -> String { try open(); return try await inner.respond(to: request) }
    func respondStructured<Output: LLMStructuredOutput>(_ type: Output.Type, to request: String) async throws -> Output {
        try open(); return try await inner.respondStructured(type, to: request)
    }
    func trim(keepingSuffix tokens: Int) async throws { try open(); try await inner.trim(keepingSuffix: tokens) }
    func warm() async throws { try open(); try await inner.warm() }
    func close() async {
        guard let lease else { return }
        self.lease = nil
        await inner.close()
        await lease.release()
    }
    private func open() throws { if lease == nil { throw LLMSessionError.closed } }

    deinit {
        // Dropped without close(): the lease must not outlive the session.
        guard let lease else { return }
        let inner = inner
        Task { await inner.close(); await lease.release() }
    }
}
