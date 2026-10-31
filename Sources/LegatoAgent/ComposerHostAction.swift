import Foundation
import LegatoRoom

/// These actions affect the composer or its already-bound insertion target, never external Send/Return.
public enum ComposerHostActionKind: String, Codable, Sendable { case clearComposer = "clear_composer", insertDraft = "insert_draft" }
public struct ComposerHostActionContext: Sendable {
    public let sessionToken: String
    public let targetToken: String?
    public let insertionUnavailableReason: String?
    public init(sessionToken: String, targetToken: String? = nil, insertionUnavailableReason: String? = nil) {
        self.sessionToken = sessionToken; self.targetToken = targetToken
        self.insertionUnavailableReason = insertionUnavailableReason
    }
    public var prompt: String {
        "Surfaces: composer/board = the current draft; Instructions = explicit app/writing instructions; target field = the already-bound external text field. clear_composer clears only this draft. insert_draft inserts into that field, never presses Return or sends a message. Insertion: " + (insertionUnavailableReason ?? (targetToken == nil ? "unavailable: no bound text field" : "available for the bound text field"))
    }
}
public struct ComposerHostAction: Sendable {
    public let id: String
    public let instructionID: String
    public let kind: ComposerHostActionKind
    public let context: ComposerHostActionContext
    public init(id: String, instructionID: String, kind: ComposerHostActionKind, context: ComposerHostActionContext) {
        self.id = id; self.instructionID = instructionID; self.kind = kind; self.context = context
    }
}
public struct ComposerHostActionResult: Sendable {
    public let succeeded: Bool
    public let message: String
    public init(succeeded: Bool, message: String) { self.succeeded = succeeded; self.message = message }
}
