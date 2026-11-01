import Foundation

public enum TransactionOrigin: String, Codable, Sendable { case asr, user, agent, undo, system }

public struct Transaction: Identifiable, Codable, Equatable, Sendable {
    public var id: String { txnId }
    public let txnId: String
    public let origin: TransactionOrigin
    public let ops: [DocOp]
    public let inverse: [DocOp]
    public let groupID: String?
    public let revision: Int
    public let hunks: [AnimationHunk]
}
