import LegatoCore

/// Pins already-prepared resources through a cleanup response; response admission never cold-loads.
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
        let lease: SelectedModelWarmup.Lease
        do { lease = try await owner.acquire(keys: [key], inBackground: true) }
        catch is CancellationError { throw CancellationError() }
        catch { throw LLMError.unavailable(reason: "Prepare the selected model in Legato before cleanup.") }
        do {
            let result = try await backend.respond(instructions: instructions, examples: examples, prompt: prompt)
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }
}
