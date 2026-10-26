import Foundation
import LegatoCore
import LegatoMLX
import LegatoModels
import Testing
@testable import LegatoPostProcessing

private let realEnabled = ProcessInfo.processInfo.environment["LEGATO_REAL_ENGINE"] == "1"

/// A persistent root so reruns reuse the download. Override with `LEGATO_TEST_MODEL_ROOT`.
private let modelRoot: URL = {
    if let path = ProcessInfo.processInfo.environment["LEGATO_TEST_MODEL_ROOT"] { return URL(fileURLWithPath: path) }
    return URL.cachesDirectory.appending(path: "LegatoTests/Models", directoryHint: .isDirectory)
}()

/// Peak resident memory of this process so far, in MB.
private func peakMemoryMB() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss) / 1_000_000  // bytes on Apple platforms
}

/// Prints what the model said before the stage's checks, so a rejected reply can be read.
private struct RecordingBackend: LLMBackend {
    let label: String
    let base: any LLMBackend
    var id: String { base.id }
    var maxPromptCharacters: Int? { base.maxPromptCharacters }
    var availability: LLMAvailability { get async { await base.availability } }

    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }

    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        do {
            let reply = try await base.respond(instructions: instructions, examples: examples, prompt: prompt)
            print("RAW[\(label)] \(reply.debugDescription)")
            return reply
        } catch {
            print("RAW[\(label)] threw \(error)")
            throw error
        }
    }
}

/// The five fixtures this smoke test started with; the larger sets and the prompt comparison live in
/// `CleanupPromptEvalTests`.
private let smokeFixtureNames: Set<String> = [
    "punctuation-casing-en", "spelled-number-de", "misrecognition-en", "spelling-de", "long-de",
]

/// Runs the smoke fixtures through ITN and then the backend's cleanup stage, prints before/after with
/// timings, and checks each output against the guard and the fixture's required words.
private func runFixtures(label: String, backend base: any LLMBackend) async throws {
    let backend = RecordingBackend(label: label, base: base)
    let guardrail = CleanupGuard()
    let itn = ITNStage()
    // Small chunks, so the long fixture crosses chunk boundaries on every backend.
    func stage(vocabulary: [String]) -> LLMCleanupStage {
        LLMCleanupStage(backend: backend, cleanupGuard: guardrail, maxChunkCharacters: 400, vocabulary: vocabulary)
    }
    let clock = ContinuousClock()

    // The first call pays model load and warm-up; time it apart from the fixtures.
    let warmStart = clock.now
    _ = try await stage(vocabulary: []).process("Hallo Welt.", locale: Locale(identifier: "de-DE"))
    print("REAL[\(label)] first call (load + warm-up): \(clock.now - warmStart)")

    for fixture in try CleanupFixtures.load(.heldout) where smokeFixtureNames.contains(fixture.name) {
        let locale = Locale(identifier: fixture.locale)
        let before = try await itn.process(fixture.input, locale: locale)
        let started = clock.now
        let after = try await stage(vocabulary: fixture.vocabulary).process(before, locale: locale)
        let elapsed = clock.now - started
        let drift = guardrail.drift(candidate: after, reference: before)
        print("""
        REAL[\(label)] \(fixture.name) | \(elapsed) | drift \(String(format: "%.3f", drift))
          before: \(before)
          after:  \(after)
        """)
        #expect(guardrail.accepts(after, reference: before), "\(label)/\(fixture.name) failed the guard")
        for word in fixture.mustContain {
            #expect(after.contains(word), "\(label)/\(fixture.name) is missing \"\(word)\": \(after)")
        }
    }
    print("REAL[\(label)] peak memory: \(peakMemoryMB()) MB")
}

/// Whether Apple's on-device model can answer on this machine, and if not, why. A test that needs it is
/// skipped with that reason instead of passing without having run.
private let foundationModelsStatus: (available: Bool, reason: String) = {
    #if canImport(FoundationModels)
    switch FoundationModelsBackend.currentAvailability() {
    case .available: return (true, "available")
    case .unavailable(let reason): return (false, reason)
    }
    #else
    return (false, "FoundationModels is not available on this platform.")
    #endif
}()

@Suite("RealCleanup", .enabled(if: realEnabled, "set LEGATO_REAL_ENGINE=1"), .serialized)
struct RealCleanupTests {
    @Test(.enabled(if: foundationModelsStatus.available, "Foundation Models unavailable: \(foundationModelsStatus.reason)"))
    func foundationModels() async throws {
        #if canImport(FoundationModels)
        try await runFixtures(label: "foundation-models", backend: FoundationModelsBackend())
        #endif
    }

    @Test func mlx() async throws {
        // The Mac checks the 1.7B model, the phone the 0.6B one (the 1.7B is not listed there).
        let defaultID = ModelPlatform.current == .macOS ? MLXModels.qwen3_1_7bID : MLXModels.qwen3_0_6bID
        let id = ProcessInfo.processInfo.environment["LEGATO_MLX_MODEL"] ?? defaultID
        let spec = try #require(MLXModels.spec(id: id))

        let defaults = UserDefaults(suiteName: "legato-real-cleanup-tests")!
        defaults.removePersistentDomain(forName: "legato-real-cleanup-tests")
        let manager = ModelManager(
            root: modelRoot,
            catalog: MLXModels.descriptors(),
            installers: MLXModels.installers(),
            selection: SelectionStore(defaults: defaults))

        // Load on pick: this is the one place the real download and warm-up happen.
        let clock = ContinuousClock()
        let started = clock.now
        try await manager.select(id, role: .cleanup)
        print("REAL[\(spec.id)] select (download if missing + load): \(clock.now - started)")

        let registry = CleanupRegistry(models: manager, foundationModels: nil)
        let resolved = await registry.resolve()
        #expect(resolved.choice == .mlx(modelID: id))
        let backend = try #require(resolved.backend)
        try await runFixtures(label: spec.id, backend: backend)
    }
}
