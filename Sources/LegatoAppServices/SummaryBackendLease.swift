import Foundation
import LegatoCore

/// A summary keeps this lease through every chunk and the final merge.
public struct SummaryBackendLease: Sendable {
    public let backend: any LLMBackend
    private let relinquish: @Sendable () async -> Void
    public init(backend: any LLMBackend, release: @escaping @Sendable () async -> Void = {}) {
        self.backend = backend; self.relinquish = release
    }
    public func release() async { await relinquish() }
}

public struct SummaryPreparationRequired: Error, Sendable, Equatable, LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(_ reason: String) { self.reason = reason }
}
