import Foundation
import LegatoCore
import LegatoMLX
import LegatoModels
import Testing
@testable import LegatoPostProcessing

// The prompt evaluation: every chosen prompt variant on every chosen model over one fixture split.
//
// It needs real models and the Metal shaders only an Xcode build produces, so it is gated and never part of CI:
//
//   TEST_RUNNER_LEGATO_REAL_ENGINE=1 TEST_RUNNER_LEGATO_EVAL_VARIANTS=V0,V1 \
//   TEST_RUNNER_LEGATO_EVAL_MODELS=qwen3-1.7b TEST_RUNNER_LEGATO_EVAL_SPLIT=dev \
//   TEST_RUNNER_LEGATO_EVAL_OUT=/some/dir xcodebuild test -scheme LegatoKit-Package \
//   -destination 'platform=macOS' -only-testing:LegatoPostProcessingTests/CleanupPromptEvalTests
//
// Variables (all after the TEST_RUNNER_ prefix xcodebuild strips):
//   LEGATO_REAL_ENGINE=1        the shared gate for real-model tests
//   LEGATO_EVAL_VARIANTS        comma-separated variant names, or "all"; required
//   LEGATO_EVAL_MODELS          comma-separated: qwen3-0.6b, qwen3-1.7b, gemma3-1b, foundation-models (default: the first three)
//   LEGATO_EVAL_SPLIT           dev (default) or heldout
//   LEGATO_EVAL_OUT             output directory (default: the temporary directory)
//   LEGATO_EVAL_ITN=1           run the English inverse text normalization first, as the pipeline does (default: off,
//                               so the prompt is judged on the raw recognizer text)
//   LEGATO_TEST_MODEL_ROOT      where models are stored and downloaded to

private let environment = ProcessInfo.processInfo.environment
private let evalEnabled = environment["LEGATO_REAL_ENGINE"] == "1" && environment["LEGATO_EVAL_VARIANTS"] != nil

private let modelRoot: URL = {
    if let path = environment["LEGATO_TEST_MODEL_ROOT"] { return URL(fileURLWithPath: path) }
    return URL.cachesDirectory.appending(path: "LegatoTests/Models", directoryHint: .isDirectory)
}()

private let modelIDs: [String: String] = [
    "qwen3-0.6b": MLXModels.qwen3_0_6bID,
    "qwen3-1.7b": MLXModels.qwen3_1_7bID,
    "gemma3-1b": MLXModels.gemma3_1bID,
]

private func csv(_ key: String) -> [String]? {
    environment[key]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// A loaded backend for `model`, or the reason there is none.
private func backend(for model: String) async throws -> (any LLMBackend, String?) {
    if model == "foundation-models" {
        #if canImport(FoundationModels)
        let candidate = FoundationModelsBackend()
        if case .unavailable(let reason) = await candidate.availability { return (candidate, reason) }
        return (candidate, nil)
        #else
        throw EvalError("FoundationModels is not available on this platform.")
        #endif
    }
    guard let id = modelIDs[model], let spec = MLXModels.spec(id: id) else { throw EvalError("unknown model \(model)") }
    let defaults = UserDefaults(suiteName: "legato-cleanup-eval")!
    defaults.removePersistentDomain(forName: "legato-cleanup-eval")
    let manager = ModelManager(
        root: modelRoot, catalog: MLXModels.descriptors(), installers: MLXModels.installers(),
        selection: SelectionStore(defaults: defaults))
    try await manager.select(id, role: .cleanup)  // downloads when missing, then loads and warms
    return (MLXBackend(spec: spec, folder: spec.folder(root: modelRoot)), nil)
}

private struct EvalError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

@Suite("CleanupPromptEval", .enabled(if: evalEnabled, "set LEGATO_REAL_ENGINE=1 and LEGATO_EVAL_VARIANTS"), .serialized)
struct CleanupPromptEvalTests {
    @Test func run() async throws {
        let variantNames = csv("LEGATO_EVAL_VARIANTS") ?? []
        let variants = variantNames == ["all"]
            ? CleanupPromptVariants.all
            : try variantNames.map { try #require(CleanupPromptVariants.named($0), "no variant \($0)") }
        let models = csv("LEGATO_EVAL_MODELS") ?? ["qwen3-0.6b", "qwen3-1.7b", "gemma3-1b"]
        let split = try #require(CleanupSplit(rawValue: environment["LEGATO_EVAL_SPLIT"] ?? "dev"))
        let useITN = environment["LEGATO_EVAL_ITN"] == "1"
        let outDir = URL(fileURLWithPath: environment["LEGATO_EVAL_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let fixtures = try CleanupFixtures.load(split)
        let itn = ITNStage()
        let clock = ContinuousClock()
        let tag = "\(split.rawValue)\(useITN ? "-itn" : "")"

        for model in models {
            let (backend, unavailable) = try await backend(for: model)
            if let unavailable {
                print("EVAL[\(model)] skipped: \(unavailable)")
                try "\(model): unavailable (\(unavailable))\n".write(
                    to: outDir.appending(path: "\(tag)-\(model)-unavailable.txt"), atomically: true, encoding: .utf8)
                continue
            }
            // The first call pays model load and warm-up; keep it out of the timings.
            let warmStart = clock.now
            _ = try? await LLMCleanupStage(backend: backend).process("hallo welt", locale: Locale(identifier: "de-DE"))
            print("EVAL[\(model)] warm-up: \(clock.now - warmStart)")

            var runs: [CleanupEvalRun] = []
            for variant in variants {
                var results: [CleanupCaseResult] = []
                for fixture in fixtures {
                    let locale = Locale(identifier: fixture.locale)
                    let input = useITN ? try await itn.process(fixture.input, locale: locale) : fixture.input
                    let stage = LLMCleanupStage(backend: backend, vocabulary: fixture.vocabulary, prompt: variant)
                    let started = clock.now
                    let chunks: [LLMCleanupStage.ChunkResult]
                    do {
                        chunks = try await stage.processChunks(input, locale: locale)
                    } catch {
                        print("EVAL[\(model)/\(variant.name)] \(fixture.name) threw \(error)")
                        chunks = [.init(input: input, reply: nil, output: input, accepted: false)]
                    }
                    let elapsed = clock.now - started
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    let output = chunks.map(\.output).joined(separator: " ")
                    let score = CleanupScorer.score(
                        output: output, input: input, fixture: fixture, rejectedChunks: chunks.filter { !$0.accepted }.count)
                    results.append(CleanupCaseResult(
                        name: fixture.name, output: output, replies: chunks.compactMap(\.reply),
                        latencySeconds: seconds, score: score))
                    print("EVAL[\(model)/\(variant.name)] \(fixture.name) \(score.passed ? "pass" : "FAIL") \(String(format: "%.2f", seconds))s | \(output)")
                }
                runs.append(CleanupEvalRun(variant: variant.name, model: model, split: split.rawValue, results: results))
                // Write after every variant, so a long run leaves usable partial results.
                let stem = "\(tag)-\(model)-\(variantNames.joined(separator: "+"))"
                try CleanupEvalReport.json(runs: runs).write(to: outDir.appending(path: "\(stem).json"))
                try CleanupEvalReport.markdown(runs: runs).write(
                    to: outDir.appending(path: "\(stem).md"), atomically: true, encoding: .utf8)
            }
            print("EVAL[\(model)] summary\n" + CleanupEvalReport.markdown(runs: runs))
        }
    }
}
