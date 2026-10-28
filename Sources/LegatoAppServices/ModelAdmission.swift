import Foundation

/// Reserves start/arm admission across resource preparation. Stop never waits for preparation.
@MainActor public final class ModelAdmission {
    public enum AdmissionError: Error { case busy }
    private var pendingID: UUID?
    private var cancelPending: (() -> Void)?
    public init() {}
    public var isPreparing: Bool { pendingID != nil || isResetting }
    public private(set) var isResetting = false
    public func cancel() { cancelPending?() }
    public func stop<Value>(operation: @MainActor () async -> Value) async -> Value {
        cancel()
        return await operation()
    }
    public func reset(operation: @MainActor () async -> Void) async {
        guard !isResetting else { return }
        isResetting = true
        cancel()
        defer { isResetting = false }
        await operation()
    }
    public func admit<Value: Sendable>(
        isIdle: @escaping @MainActor () -> Bool,
        canStart: @escaping @MainActor () -> Bool = { true },
        resolve: @escaping @MainActor () async throws -> Void = {},
        prepare: @escaping @MainActor () async throws -> Void,
        operation: @escaping @MainActor () async -> Value
    ) async throws -> Value {
        guard pendingID == nil, !isResetting, isIdle() else { throw AdmissionError.busy }
        let id = UUID()
        pendingID = id
        let task = Task { @MainActor in
            try await resolve()
            try Task.checkCancellation()
            guard isIdle(), canStart(), !self.isResetting else { throw AdmissionError.busy }
            try await prepare()
            try Task.checkCancellation()
            guard isIdle(), canStart(), !self.isResetting else { throw AdmissionError.busy }
            return await operation()
        }
        cancelPending = { task.cancel() }
        defer { if pendingID == id { pendingID = nil; cancelPending = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    /// A canceled admission leaves shared engine resolution running, but returns without late capture.
    public static func waitForResolution(_ task: Task<Void, Never>) async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { await task.value; continuation.yield(()); continuation.finish() }
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }
}
