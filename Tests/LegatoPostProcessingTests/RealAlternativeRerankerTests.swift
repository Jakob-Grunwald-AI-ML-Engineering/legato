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

/// Whether Apple's on-device model can answer on this machine, and if not, why.
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

private struct Fixture {
    var sentence: String
    var word: String
    var candidates: [String]
    var expected: String
}

/// The tapped word is misheard; the right candidate is never first, so a model that does nothing scores 0.
private let fixtures: [Fixture] = [
    Fixture(sentence: "we host the service on kuber netties in the cloud", word: "kuber", candidates: ["Kuper", "Kubernetes", "Kiber"], expected: "Kubernetes"),
    Fixture(sentence: "please ask kloud to summarize the document", word: "kloud", candidates: ["Cloud", "Claude", "Clout"], expected: "Claude"),
    Fixture(sentence: "ask jon from the sails team about the numbers", word: "sails", candidates: ["sail", "sales", "sells"], expected: "sales"),
    Fixture(sentence: "I will meet you their at noon", word: "their", candidates: ["thy", "there", "they're"], expected: "there"),
    Fixture(sentence: "the document is on conf fluence since monday", word: "conf", candidates: ["Conf", "Confluence", "cough"], expected: "Confluence"),
    Fixture(sentence: "wir treffen uns bei familie grünwald zum essen", word: "grünwald", candidates: ["Grünwall", "Grunewald", "Grünwald"], expected: "Grünwald"),
    Fixture(sentence: "der termin ist am montag in der kuber netes konferenz", word: "kuber", candidates: ["Kuper", "Kubernetes", "Kuver"], expected: "Kubernetes"),
    Fixture(sentence: "ich habe das ticket in jira angelegt und in schlack gepostet", word: "schlack", candidates: ["Schlag", "Slack", "Schlacke"], expected: "Slack"),
    Fixture(sentence: "das paket kommt von der fer sand firma", word: "fer", candidates: ["für", "Versand", "fern"], expected: "Versand"),
    Fixture(sentence: "we read the whether report before the launch", word: "whether", candidates: ["wether", "weather", "wither"], expected: "weather"),
]

private func evaluate(label: String, backend: any LLMBackend) async {
    // A generous timeout: this measures the model, not the 2 s production budget.
    let reranker = LLMAlternativeReranker(backend: backend, timeout: .seconds(60))
    let clock = ContinuousClock()
    // The first call pays model load and warm-up.
    let warm = clock.now
    _ = await reranker.rerank(word: "kloud", sentence: "ask kloud now", wordRange: "ask kloud now".range(of: "kloud")!, candidates: ["Cloud", "Claude"])
    print("REAL-RERANK[\(label)] first call (load + warm-up): \(clock.now - warm)")

    var hits = 0
    var latencies: [Double] = []
    for fixture in fixtures {
        let started = clock.now
        let out = await reranker.rerank(
            word: fixture.word, sentence: fixture.sentence,
            wordRange: fixture.sentence.range(of: fixture.word)!, candidates: fixture.candidates)
        let parts = (clock.now - started).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        latencies.append(seconds)
        let hit = out.first == fixture.expected
        if hit { hits += 1 }
        print("REAL-RERANK[\(label)] \(hit ? "hit " : "miss") \(String(format: "%.2f", seconds))s \(fixture.word) -> \(out)")

        // Never garbage: a subset of the candidates, plus at most one proposal.
        #expect(out.count <= 3)
        #expect(Set(out).count == out.count)
        let foreign = out.filter { !fixture.candidates.contains($0) }
        #expect(foreign.count <= 1, "\(label)/\(fixture.word): \(foreign) are not candidates")
        for proposal in foreign {
            #expect(LLMAlternativeReranker.soundsLike(proposal, fixture.word), "\(label): ungated proposal \(proposal)")
        }
    }
    let mean = latencies.reduce(0, +) / Double(latencies.count)
    print("REAL-RERANK[\(label)] hit@1 \(hits)/\(fixtures.count) | latency mean \(String(format: "%.2f", mean))s max \(String(format: "%.2f", latencies.max() ?? 0))s")
}

@Suite("RealAlternativeReranker", .enabled(if: realEnabled, "set LEGATO_REAL_ENGINE=1"), .serialized)
struct RealAlternativeRerankerTests {
    @Test(.enabled(if: foundationModelsStatus.available, "Foundation Models unavailable: \(foundationModelsStatus.reason)"))
    func foundationModels() async {
        #if canImport(FoundationModels)
        await evaluate(label: "foundation-models", backend: FoundationModelsBackend())
        #endif
    }

    @Test func mlx() async throws {
        let defaultID = ModelPlatform.current == .macOS ? MLXModels.qwen3_1_7bID : MLXModels.qwen3_0_6bID
        let id = ProcessInfo.processInfo.environment["LEGATO_MLX_MODEL"] ?? defaultID
        _ = try #require(MLXModels.spec(id: id))

        let defaults = UserDefaults(suiteName: "legato-real-rerank-tests")!
        defaults.removePersistentDomain(forName: "legato-real-rerank-tests")
        let manager = ModelManager(
            root: modelRoot,
            catalog: MLXModels.descriptors(),
            installers: MLXModels.installers(),
            selection: SelectionStore(defaults: defaults))
        try await manager.select(id, role: .cleanup)

        let registry = CleanupRegistry(models: manager, foundationModels: nil)
        let backend = try #require(await registry.resolve().backend)
        await evaluate(label: id, backend: backend)
    }
}
