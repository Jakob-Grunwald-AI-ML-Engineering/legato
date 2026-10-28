import Foundation
import LegatoCore
import LegatoCoreML
import Testing
@testable import LegatoPostProcessing

private struct WritingModeCall: Codable, Sendable {
    let instructions: String
    let examples: [WritingModeExample]
    let userMessage: String
    let promptHash: String
    let rawCandidate: String?
    let rawCandidateSHA256: String?
    let error: String?
    let latencySeconds: Double
    let settlementSeconds: Double
    let timedOut: Bool
    let settled: Bool
}

private struct WritingModeExample: Codable, Sendable {
    let user: String
    let assistant: String
}

private actor WritingModeTrace {
    var calls: [WritingModeCall] = []
    var pending = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    func start(_ call: WritingModeCall) -> Int { pending += 1; calls.append(call); return calls.count - 1 }
    func finish(_ index: Int, _ call: WritingModeCall) {
        calls[index] = call
        pending -= 1
        if pending == 0 { let ready = waiters; waiters = []; ready.forEach { $0.resume() } }
    }
    func waitUntilFinished() async {
        if pending == 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func snapshot() -> [WritingModeCall] { calls }
}

/// Records the actual production-stage requests and raw responses; never supplies a replacement model.
private struct WritingModeRecordingBackend: LLMBackend {
    let base: any LLMBackend
    let trace: WritingModeTrace
    var id: String { base.id }
    var maxPromptCharacters: Int? { base.maxPromptCharacters }
    var availability: LLMAvailability { get async { await base.availability } }

    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        let evidence = examples.map { WritingModeExample(user: $0.user, assistant: $0.assistant) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let promptBytes = try encoder.encode(WritingModePromptEvidence(instructions: instructions, examples: evidence, userMessage: prompt))
        let promptHash = writingModeHash(promptBytes)
        let callIndex = await trace.start(.init(instructions: instructions, examples: evidence, userMessage: prompt,
                                                promptHash: promptHash, rawCandidate: nil, rawCandidateSHA256: nil,
                                                error: "in-flight at snapshot; settlement unknown", latencySeconds: 0,
                                                settlementSeconds: 0, timedOut: false, settled: false))
        let start = Date()
        let result = await writingModeBounded(seconds: 60) { [base] in
            try await base.respond(instructions: instructions, examples: examples, prompt: prompt)
        }
        let generationSeconds = Date().timeIntervalSince(start)
        let settlementStart = Date()
        var settled = true
        if result.timedOut || Task.isCancelled {
            (base as? CoreMLBackend)?.cancel()
            settled = await writingModeWaitForSettlement(worker: result.worker, seconds: 5)
        }
        let raw = try? result.result.get()
        let error: String?
        if case .failure(let failure) = result.result { error = String(describing: failure) } else { error = nil }
        await trace.finish(callIndex, .init(instructions: instructions, examples: evidence, userMessage: prompt,
                                           promptHash: promptHash, rawCandidate: raw,
                                           rawCandidateSHA256: raw.map { writingModeHash(Data($0.utf8)) }, error: error,
                                           latencySeconds: generationSeconds, settlementSeconds: Date().timeIntervalSince(settlementStart),
                                           timedOut: result.timedOut, settled: settled))
        return try result.result.get()
    }
}

private struct WritingModePromptEvidence: Codable {
    let instructions: String
    let examples: [WritingModeExample]
    let userMessage: String
}

private struct WritingModeCaseRecord: Codable {
    let fixture: WritingModeFixture
    let calls: [WritingModeCall]
    let deliveredOutput: String?
    let deliveredHash: String?
    let objectiveFailures: [String]
    let operationalFailures: [String]
    let latencySeconds: Double
    let usage: String
    let independentReview: String
    let productionDeadlineSeconds: Double
    let deadlineConfiguration: WritingModeDeadline
    let timedOut: Bool
    let failed: Bool
    let guardRejected: Bool
    let rawPreserved: Bool
    let settledBeforeNextCase: Bool
}

private struct WritingModeModelRecord: Codable {
    let model: String
    let split: WritingModeSplit
    var status: String = "pending"
    var reason: String?
    var backendID: String?
    var repository: String?
    var artifactRevision: String?
    var installReceiptSHA256: String?
    var artifactFolder: String?
    var preparationSeconds: Double?
    var preparationSettled: Bool = true
    var releaseSettled: Bool?
    var cases: [WritingModeCaseRecord] = []
}

private struct WritingModeRunRecord: Codable {
    var schemaVersion: Int = 1
    let startedAt: Date
    let os: String
    let fixtureSHA256: String
    let sourceSHA256: [String: String]
    let sourceRevision: String
    let dependencyMode: String
    var execution: String = "production backends; installed assets only; no ITN"
    let preparationDeadlineSeconds: Double
    let foundationModelsDeadline: WritingModeDeadline
    let coreMLDeadline: WritingModeDeadline
    var limits: String = "actual pipeline deadline defaults Core ML 8s / Foundation Models 4s; optional explicit user timeout setting 1...10s recorded separately; response safety cap 60s; cancellation grace 5s plus trace settlement wait 6s; never reuse unsettled backend"
    var models: [WritingModeModelRecord]
    var summary = WritingModeSummary()
    var reviewStatus: String = "pending independent semantic and naturalness review; not validated quality"
}

private let writingModeEnvironment = ProcessInfo.processInfo.environment

@Suite("CleanupWritingModeEvalTests", .enabled(if: writingModeEnvironment["LEGATO_REAL_ENGINE"] == "1", "set LEGATO_REAL_ENGINE=1"), .serialized)
struct CleanupWritingModeEvalTests {
    @Test func installedProductionBackends() async throws {
        let env = writingModeEnvironment
        guard let split = WritingModeSplit(rawValue: env["LEGATO_WRITING_SPLIT"] ?? "dev") else {
            throw WritingModeEvalError("LEGATO_WRITING_SPLIT must be dev or validation")
        }
        let fixtures = try WritingModeFixtures.load(split)
        let foundationModelsDeadline = try WritingModeDeadline(defaultSeconds: 4, configured: env["LEGATO_WRITING_TIMEOUT_SECONDS"])
        let coreMLDeadline = try WritingModeDeadline(defaultSeconds: 8, configured: env["LEGATO_WRITING_TIMEOUT_SECONDS"])
        let preparationDeadline = Double(env["LEGATO_WRITING_PREPARE_SECONDS"] ?? "300") ?? -1
        guard preparationDeadline.isFinite, (1...1800).contains(preparationDeadline) else {
            throw WritingModeEvalError("LEGATO_WRITING_PREPARE_SECONDS must be between 1 and 1800")
        }
        let selectors = env["LEGATO_WRITING_MODELS"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            ?? (CoreMLModels.specs.map(\.id) + ["foundation-models"])
        guard !selectors.isEmpty, Set(selectors).count == selectors.count else { throw WritingModeEvalError("Empty or duplicate model selectors") }
        let output = URL(fileURLWithPath: env["LEGATO_WRITING_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "writing-modes-\(split.rawValue)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reportURL = output.appending(path: "evidence.json")
        let root = env["LEGATO_WRITING_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sources: [String: String] = [:]
        for path in ["Package.swift", "Package.resolved", "Sources/LegatoPostProcessing/CleanupStyle.swift", "Sources/LegatoPostProcessing/CleanupEmojiStyle.swift", "Sources/LegatoPostProcessing/CleanupPrompt.swift", "Sources/LegatoPostProcessing/LLMCleanupStage.swift", "Sources/LegatoPostProcessing/FoundationModelsBackend.swift", "Sources/LegatoCoreML/CoreMLBackend.swift", "Sources/LegatoCoreML/NativeCoreMLDriver.swift", "Tests/LegatoPostProcessingTests/Eval/WritingModeHarness.swift", "Tests/LegatoPostProcessingTests/Eval/CleanupWritingModeEvalTests.swift"] {
            if let data = try? Data(contentsOf: sourceRoot.appending(path: path)) { sources[path] = writingModeHash(data) }
        }
        var report = WritingModeRunRecord(startedAt: Date(), os: ProcessInfo.processInfo.operatingSystemVersionString,
                                         fixtureSHA256: writingModeHash(try encoder.encode(fixtures)), sourceSHA256: sources,
                                         sourceRevision: env["LEGATO_WRITING_REVISION"] ?? "unspecified; sourceSHA256 records checkout files at evaluation time, not a binary attestation",
                                         dependencyMode: env["LEGATO_STUB_DEPS"] == "1" ? "stub external dependencies; Apple FoundationModels implementation remains real; Core ML proof disabled" : "real external dependencies requested; verify build provenance independently",
                                         preparationDeadlineSeconds: preparationDeadline,
                                         foundationModelsDeadline: foundationModelsDeadline, coreMLDeadline: coreMLDeadline,
                                         models: selectors.map { WritingModeModelRecord(model: $0, split: split) })
        func save() throws { try encoder.encode(report).write(to: reportURL, options: .atomic) }
        try save()
        print("Writing-mode synthetic evidence: \(reportURL.path)")

        for (index, selector) in selectors.enumerated() {
            var record = report.models[index]
            let backend: any LLMBackend
            let lifecycle: any ModelResourceLifecycle
            if env["LEGATO_STUB_DEPS"] == "1" && selector != "foundation-models" {
                record.status = "unavailable"
                record.reason = "LEGATO_STUB_DEPS=1 is harness-only, never production model proof"
                report.summary.unavailable += 1
                report.models[index] = record
                try save()
                continue
            }
            if selector == "foundation-models" {
                #if canImport(FoundationModels)
                let model = FoundationModelsBackend()
                backend = model
                lifecycle = model
                record.artifactRevision = "Apple system-managed; exact weight revision unavailable; OS recorded at run level"
                #else
                record.status = "unavailable"
                record.reason = "FoundationModels framework unavailable"
                report.summary.unavailable += 1
                report.models[index] = record
                try save()
                continue
                #endif
            } else if let spec = CoreMLModels.spec(id: selector) {
                record.repository = spec.repo
                record.artifactRevision = spec.revision
                guard let root else {
                    record.status = "unavailable"
                    record.reason = "No explicit LEGATO_WRITING_ROOT; no filesystem search performed"
                    report.summary.unavailable += 1
                    report.models[index] = record
                    try save()
                    continue
                }
                let folder = spec.folder(root: root)
                record.artifactFolder = folder.path
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    record.status = "unavailable"
                    record.reason = "Installed artifact absent; downloads disabled"
                    report.summary.unavailable += 1
                    report.models[index] = record
                    try save()
                    continue
                }
                if let receipt = try? Data(contentsOf: folder.appending(path: ".legato-coreml-verified.json")) {
                    record.installReceiptSHA256 = writingModeHash(receipt)
                }
                let model = CoreMLBackend(spec: spec, folder: folder)
                backend = model
                lifecycle = model
            } else {
                record.status = "unavailable"
                record.reason = "Unknown selector; use current CoreMLModels.specs IDs or foundation-models"
                report.summary.unavailable += 1
                report.models[index] = record
                try save()
                continue
            }
            record.backendID = backend.id
            if selector == "foundation-models", case .unavailable(let reason) = await backend.availability {
                record.status = "unavailable"
                record.reason = reason
                report.summary.unavailable += 1
                report.models[index] = record
                try save()
                continue
            }
            let preparedAt = Date()
            // Core ML is unavailable before prepare by design; Foundation Models can be checked first.
            let prepared = await writingModeBounded(seconds: preparationDeadline) {
                try await lifecycle.prewarmResources()
                if case .unavailable(let reason) = await backend.availability { throw WritingModeEvalError(reason) }
                return true
            }
            record.preparationSeconds = Date().timeIntervalSince(preparedAt)
            if case .failure(let error) = prepared.result {
                (backend as? CoreMLBackend)?.cancel()
                let settlement = await writingModeBounded(seconds: 5) { await prepared.worker.value; return true }
                record.preparationSettled = (try? settlement.result.get()) == true
                record.status = "unavailable"
                record.reason = "Preparation failed: \(error); settled=\(record.preparationSettled)"
                report.summary.unavailable += 1
                report.summary.operationalFailures += 1
                report.models[index] = record
                try save()
                if record.preparationSettled {
                    let released = await writingModeBounded(seconds: 5) { await lifecycle.releaseWarmResources(); return true }
                    record.releaseSettled = (try? released.result.get()) == true
                    if record.releaseSettled != true { report.summary.operationalFailures += 1 }
                    report.models[index] = record
                    try save()
                }
                continue
            }
            record.status = "prepared"
            report.models[index] = record
            try save()
            var safeToRelease = true
            for (caseIndex, fixture) in fixtures.enumerated() {
                guard let style = CleanupStyle(rawValue: fixture.mode), let emoji = MessageEmojiStyle(rawValue: fixture.emoji) else {
                    throw WritingModeEvalError("Invalid mode API contract: \(fixture.id)")
                }
                let trace = WritingModeTrace()
                let recording = WritingModeRecordingBackend(base: backend, trace: trace)
                let stage = LLMCleanupStage(backend: recording, prompt: style.prompt(emoji: emoji), acceptance: .promptLed)
                let deadline = selector == "foundation-models" ? foundationModelsDeadline : coreMLDeadline
                let productionDeadline = deadline.appliedSeconds
                let pipeline = PostProcessingPipeline(stages: [stage], timeout: .seconds(productionDeadline))
                let start = Date()
                let deliveredReport = await pipeline.processReporting(fixture.input, locale: Locale(identifier: fixture.locale))
                let deliverySeconds = Date().timeIntervalSince(start)
                var operational: [String] = []
                if deliveredReport.timedOut { operational.append("production pipeline deadline exceeded") }
                if deliveredReport.failed { operational.append("production pipeline failed") }
                if deliveredReport.guardRejected { operational.append("production pipeline rejected candidate") }
                if deliveredReport.timedOut || deliveredReport.failed { (backend as? CoreMLBackend)?.cancel() }
                let settlement = await writingModeBounded(seconds: 6) {
                    await trace.waitUntilFinished()
                    if let core = backend as? CoreMLBackend { await core.waitUntilSettled() }
                    return true
                }
                safeToRelease = (try? settlement.result.get()) == true
                if !safeToRelease { operational.append("UNSETTLED after production delivery; backend abandoned") }
                let calls = await trace.snapshot()
                operational += calls.compactMap(\.error)
                if calls.contains(where: { call in
                    call.rawCandidate.map { style.prompt(emoji: emoji).extractText($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
                }) { operational.append("empty extracted candidate; runtime fallback is not a quality pass") }
                if calls.contains(where: { !$0.settled }) { safeToRelease = false }
                if calls.isEmpty { operational.append("no generation recorded") }
                let delivered = deliveredReport.text
                let failures = WritingModeChecks.failures(delivered, fixture: fixture)
                report.summary.completed += calls.contains(where: { $0.rawCandidate != nil }) ? 1 : 0
                report.summary.objectiveFailures += failures.isEmpty ? 0 : 1
                report.summary.operationalFailures += operational.isEmpty ? 0 : 1
                record.cases.append(.init(fixture: fixture, calls: calls, deliveredOutput: delivered,
                                          deliveredHash: writingModeHash(Data(delivered.utf8)),
                                          objectiveFailures: failures, operationalFailures: operational,
                                          latencySeconds: deliverySeconds,
                                          usage: caseIndex == 0 ? "first generation after cold prepare" : "warm owner reused; system residency not guaranteed",
                                          independentReview: "pending independent side-by-side review",
                                          productionDeadlineSeconds: productionDeadline, deadlineConfiguration: deadline, timedOut: deliveredReport.timedOut,
                                          failed: deliveredReport.failed, guardRejected: deliveredReport.guardRejected,
                                          rawPreserved: delivered == fixture.input, settledBeforeNextCase: safeToRelease))
                report.models[index] = record
                try save()
                #expect(failures.isEmpty, "\(selector)/\(fixture.id): objective failures \(failures); see evidence.json")
                #expect(operational.isEmpty, "\(selector)/\(fixture.id): operational failures \(operational)")
                if !safeToRelease {
                    record.status = "aborted-unsettled"
                    record.reason = "Remaining \(fixtures.count - caseIndex - 1) cases not run; no further calls on this backend"
                    break
                }
            }
            if record.status == "prepared" { record.status = "completed" }
            report.models[index] = record
            try save()
            if safeToRelease {
                let released = await writingModeBounded(seconds: 5) { await lifecycle.releaseWarmResources(); return true }
                record.releaseSettled = (try? released.result.get()) == true
                if record.releaseSettled != true { report.summary.operationalFailures += 1 }
                report.models[index] = record
                try save()
            }
        }
        try save()
        #expect(report.summary.completed > 0, "No production backend produced output; unavailable is not quality success")
        #expect(report.summary.operationalFailures == 0, "Operational failures recorded independently in evidence.json")
        #expect(report.summary.objectiveFailures == 0, "Tested quality failures recorded in evidence.json")
    }
}
