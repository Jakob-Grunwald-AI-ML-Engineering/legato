import Foundation

/// The metadata shared by the app's publication, the keyboard's receipt and the History checkpoint.
public struct PreviewDiagnosticRevision: Sendable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case awaitingCleanup, ready, released
    }

    public let runID: UUID
    public let revision: Int
    public let unitID: Int
    public let operationID: UUID
    public let phase: Phase
    public let inputCharacters: Int
    public let resultCharacters: Int?
}

extension LiveDictationSnapshot {
    public func previewDiagnosticRevision(unitID: Int? = nil) -> PreviewDiagnosticRevision? {
        guard let segment = previewDiagnosticSegment(unitID: unitID), let operationID = segment.previewOperationID else { return nil }
        return previewDiagnosticRevision(segment, operationID: operationID)
    }

    fileprivate func previewDiagnosticSegment(unitID: Int? = nil) -> LiveSegment? {
        segments.last { $0.previewOperationID != nil && (unitID == nil || unitID == $0.id) }
    }

    fileprivate func previewDiagnosticRevision(_ segment: LiveSegment, operationID: UUID) -> PreviewDiagnosticRevision? {
        guard let runID = UUID(uuidString: runID) else { return nil }
        let phase = segment.previewDiagnosticPhase
        return PreviewDiagnosticRevision(runID: runID, revision: version, unitID: segment.id, operationID: operationID,
            phase: phase, inputCharacters: segment.previewOriginal.count,
            resultCharacters: phase == .awaitingCleanup ? nil : segment.text.count)
    }
}

private extension LiveSegment {
    var previewDiagnosticPhase: PreviewDiagnosticRevision.Phase {
        if previewReleased == true { return .released }
        return ready == true ? .ready : .awaitingCleanup
    }
}

/// Ordinary speech can advance the snapshot version while the same Magic result is still on screen.
/// Report each phase once per operation rather than writing a breadcrumb for every version.
public struct PreviewDiagnosticCursor {
    private var runID: String?
    private var version: Int?
    private var operationID: UUID?
    private var phase: PreviewDiagnosticRevision.Phase?

    public init() {}

    public mutating func changed(in snapshot: LiveDictationSnapshot) -> PreviewDiagnosticRevision? {
        guard snapshot.runID != runID || snapshot.version != version else { return nil }
        runID = snapshot.runID
        version = snapshot.version
        guard let segment = snapshot.previewDiagnosticSegment(), let nextID = segment.previewOperationID,
              nextID != operationID || segment.previewDiagnosticPhase != phase,
              let revision = snapshot.previewDiagnosticRevision(segment, operationID: nextID) else { return nil }
        operationID = nextID
        phase = segment.previewDiagnosticPhase
        return revision
    }
}
