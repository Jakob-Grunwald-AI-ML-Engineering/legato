import Foundation

/// A finished dictation that waits in the Live Activity for its Insert or Copy button.
public struct DictationResult: Sendable, Equatable {
    /// How long the result stays actionable, and the activity stays up.
    public static let lifetime: TimeInterval = 120

    public let runID: String
    public let text: String
    public let at: Date

    public init(runID: String, text: String, at: Date) {
        self.runID = runID
        self.text = text
        self.at = at
    }

    public func isActionable(now: Date) -> Bool {
        !text.isEmpty && now.timeIntervalSince(at) <= Self.lifetime
    }
}

/// What a result button did.
public enum ResultOutcome: Sendable, Equatable {
    /// The Legato keyboard confirmed the text is in its field.
    case inserted
    /// No Legato keyboard acted (not on screen, or it did not confirm in time).
    case keyboardNotActive
    case copied
    /// The pasteboard did not change (a background write can be dropped).
    case copyFailed

    /// The activity's state after it.
    public var phase: DictationPhase {
        switch self {
        case .inserted: .inserted
        case .keyboardNotActive: .insertFailed
        case .copied: .copied
        case .copyFailed: .tapToCopy
        }
    }

    /// Whether the activity ends with this outcome. A failed insert keeps it up, so Insert can be tried
    /// again (the keyboard may be up by then) or Copy used instead.
    public var endsActivity: Bool { self != .keyboardNotActive }
}

extension DictationPhase {
    /// The activity shows the Insert and Copy buttons.
    public var offersResultActions: Bool { self == .result || self == .insertFailed }
}
