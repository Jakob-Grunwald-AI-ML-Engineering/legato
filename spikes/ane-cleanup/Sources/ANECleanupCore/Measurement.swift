import Foundation
import Darwin

/// An explicit null means the backend does not expose that exact metric.
public struct Measurement: Codable, Sendable {
    public var schema = 1
    public var runID = UUID().uuidString
    public var timestamp = Date()
    public var requestedBackend: String
    public var executedBackend: String?
    public var modelRevision: String
    public var prompt = "Legato CleanupPrompt.standard; all eleven examples"
    public var promptFamily: String
    public var trigger: String
    public var startClassification: String
    public var appStateAtTrigger: String
    public var appStateAtSettlement: String?
    public var foregroundInterruptedAt: Date?
    public var backgroundCompletionEligible: Bool?
    public var workerSettlement: String?
    public var appStateAtInference: String
    public var computePermission = "cpuAndNeuralEngine"
    public var cpuCompilation: String?
    public var anePlacement = "unverified; requires Instruments"
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var outputCap: Int? = 1024
    public var contextLength: Int?
    public var tokenizerLoadMs: Double?
    public var tokenizationMs: Double?
    public var modelLoadMs: Double?
    public var prefillMs: Double?
    public var firstTokenMs: Double?
    public var decodeMs: Double?
    public var endToEndMs: Double?
    public var sampledPeakBytes: UInt64?
    public var cancellationRequestedAt: Date?
    public var publicBackendReturnedAt: Date?
    public var settledAt: Date?
    public var status = "started"
    public var error: String?
    public var fixtureDeadlineSeconds: Int?
    public var workload = "cleanupFixture"
    public var cacheState = "unknown"
    public var modelValidation: String?
    public var artifactManifestSHA256: String?
    public var modelMetadataSHA256: String?
    public var conversionManifestSHA256: String?
    public var modelQuantization: String?
    public var renderedPromptSHA256: String?
    public var buildID: String?
    public var tokenizerRevision: String?
    public var semanticPromptSHA256: String?
    public var deviceModel: String = {
        var name = utsname(); uname(&name)
        let capacity = MemoryLayout.size(ofValue: name.machine)
        return withUnsafePointer(to: &name.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }()
    public var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    public var batteryLevel: Float?
    public var batteryState: String?
    public var fixture: String?
    public var inputCharacters: Int?
    public var outputCharacters: Int?
    public var rawPreserved: Bool?
    public var metricScope: String?
    public var backendInvocationCount: Int?
    public var backendSuccessfulInvocationCount: Int?
    public var backendFailedInvocationCount: Int?
    public var rawCandidate: String?
    public var extractedText: String?
    public var stopReason: String?
    public var qualityPassed: Bool?
    public var guardAccepted: Bool?
    public var finalText: String?
    public var buildConfiguration: String
    public var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    public var thermalState = String(describing: ProcessInfo.processInfo.thermalState)
    public var pid = ProcessInfo.processInfo.processIdentifier

    public init(backend: String, revision: String, family: String, trigger: String, classification: String,
                state: String, buildConfiguration: String) {
        requestedBackend = backend; modelRevision = revision; promptFamily = family
        self.trigger = trigger; startClassification = classification; appStateAtTrigger = state; appStateAtInference = "notStarted"
        self.buildConfiguration = buildConfiguration
        if backend == "mlx-cpu" { cpuCompilation = "disabled; interpreted MLX ops" }
        if backend != "anemll" { computePermission = backend == "mlx-cpu" ? "cpu" : "system managed" }
    }
}
