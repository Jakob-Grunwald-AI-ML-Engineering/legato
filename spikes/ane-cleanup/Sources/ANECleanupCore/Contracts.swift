import Foundation
import Synchronization

public enum SpikeError: Error, Equatable { case contextBudget, busy, cancelled, invalidMeasurement }
public struct ChatTurn: Sendable, Equatable {
    public var role: String
    public var content: String
    public init(_ role: String, _ content: String) { self.role = role; self.content = content }
}
public enum PromptFamily: String, Codable, Sendable { case qwen3, gemma3 }
public enum PromptRenderer {
    public static func render(_ turns: [ChatTurn], family: PromptFamily) -> String {
        switch family {
        case .qwen3:
            return turns.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>\n" }.joined()
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .gemma3:
            var system = ""
            var result = "<bos>"
            for turn in turns {
                if turn.role == "system" { system += turn.content; continue }
                let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = system.isEmpty ? trimmed : system + "\n\n" + trimmed
                system = ""
                result += "<start_of_turn>\(turn.role == "assistant" ? "model" : "user")\n\(content)<end_of_turn>\n"
            }
            return result + "<start_of_turn>model\n"
        }
    }
}
public enum ContextBudget {
    public static func validate(input: Int, outputCap: Int, context: Int, exactBucket: Int? = nil) throws {
        guard input > 0, outputCap > 0, context > outputCap, input <= context - outputCap - 2,
              exactBucket == nil || exactBucket == input else { throw SpikeError.contextBudget }
    }
}
public final class RunLease: Sendable {
    private let state = Mutex((running: false, cancelled: false))
    public init() {}
    public func begin() throws {
        try state.withLock { value in
            guard !value.running else { throw SpikeError.busy }
            value = (true, false)
        }
    }
    public func cancel() { state.withLock { $0.cancelled = true } }
    public func check() throws {
        try state.withLock { if $0.cancelled { throw CancellationError() } }
    }
    public var isRunning: Bool { state.withLock { $0.running } }
    public func settle() { state.withLock { $0.running = false } }
}
public enum StartClassification {
    public static func classify(entryState: String, recordingState: String, foregroundHop: Bool, armedForeground: Bool) -> String {
        if foregroundHop { return "foregroundHop" }
        if armedForeground && recordingState == "background" { return "foregroundArmedBackground" }
        if entryState == "background" && recordingState == "background" { return "backgroundStart" }
        return "foregroundStart"
    }
}

/// A labelled synthetic workload, independent of the unchanged cleanup prompt and quality fixtures.
public enum SyntheticInput {
    public static func userText(totalTokens: Int, countRendered: (String) throws -> Int) throws -> String {
        let overhead = try countRendered("")
        guard totalTokens > overhead else { throw SpikeError.contextBudget }
        var words = totalTokens - overhead
        for _ in 0..<8 {
            let text = String(repeating: " hello", count: max(0, words))
            let count = try countRendered(text)
            if count == totalTokens { return text }
            words += totalTokens - count
            guard words > 0 else { throw SpikeError.contextBudget }
        }
        throw SpikeError.contextBudget
    }
}

public enum VoiceOutcome {
    public static func classify(cancelled: Bool, timedOut: Bool, guardRejected: Bool, backendSucceeded: Bool, capped: Bool) -> String {
        if cancelled { return "cancelled" }
        if timedOut { return "timedOut" }
        if capped { return "capped" }
        if guardRejected { return "guardRejected" }
        return backendSucceeded ? "completed" : "rawOrUnavailable"
    }
}

public enum FixtureDeadline {
    public static func seconds(appState: String, modelCold: Bool) -> Int { appState == "active" && modelCold ? 300 : 60 }
}

/// Owns public backend invocations, plus a conservative quarantine for opaque native cancellation.
/// A public stream finishing does not establish that MLX's internal evaluation worker has joined.
public final class WorkerOwnership: Sendable {
    private struct State {
        var runID = ""
        var workers = 0
        var invoked = false
        var cancelled = false
        var opaque = false
        var quarantined = false
        var backgroundStart = false
        var foregroundAt: Date?
    }
    private let state = Mutex(State())
    public init() {}
    public func requireReusable() throws {
        try state.withLock { value in
            guard !value.quarantined, value.workers == 0 else { throw SpikeError.busy }
        }
    }
    public func beginRun(id: String, opaqueCancellation: Bool, state appState: String) throws {
        try state.withLock { value in
            guard !value.quarantined, value.workers == 0 else { throw SpikeError.busy }
            value = State(runID: id, opaque: opaqueCancellation, backgroundStart: appState == "background")
        }
    }
    public func beginWorker(runID: String) throws {
        try state.withLock { value in
            guard value.runID == runID, !value.cancelled, !value.quarantined else { throw CancellationError() }
            value.workers += 1; value.invoked = true
        }
    }
    public func finishWorker(cancelled: Bool) {
        state.withLock { value in
            if cancelled { value.cancelled = true; if value.opaque { value.quarantined = true } }
            value.workers -= 1
        }
    }
    public func cancel() {
        state.withLock { value in
            value.cancelled = true
            if value.opaque && value.invoked { value.quarantined = true }
        }
    }
    public var canContinueBatch: Bool { state.withLock { !$0.cancelled && !$0.quarantined } }
    public var isQuarantined: Bool { state.withLock { $0.quarantined } }
    public func wasInvoked(runID: String) -> Bool { state.withLock { $0.runID == runID && $0.invoked } }
    public func observe(state appState: String) {
        state.withLock { value in
            if value.backgroundStart && appState == "active" && value.foregroundAt == nil { value.foregroundAt = Date() }
        }
    }
    public var foregroundInterruptedAt: Date? { state.withLock { $0.foregroundAt } }
    public func backgroundEligible(settlementState: String) -> Bool {
        state.withLock { $0.backgroundStart && $0.foregroundAt == nil && settlementState == "background" }
    }
    public func waitUntilSettled() async {
        await Task.detached { [self] in
            while state.withLock({ $0.workers > 0 }) { try? await Task.sleep(for: .milliseconds(20)) }
        }.value
    }
}

public enum CancellationTimestamp {
    public static func retain(first: Date?, requested: Date) -> Date { first ?? requested }
}
