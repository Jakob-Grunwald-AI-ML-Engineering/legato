import Foundation

/// Unforgeable outside this module; Room accepts publications rather than arbitrary doc channel payloads.
public struct DocWriter: Sendable { fileprivate init() {} }
public enum DocumentEvent: Codable, Equatable, Sendable {
    case ops(Transaction)
    case snapshot(DocumentSnapshot)
}
public struct DocumentPublication: Sendable {
    public let event: DocumentEvent
    private let writer: DocWriter
    init(event: DocumentEvent) { self.event = event; self.writer = DocWriter() }
}
