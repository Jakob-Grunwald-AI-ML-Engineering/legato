import Foundation
import LegatoCore
import Observation

/// The engine new sessions get; replaced when the pick or the engine settings change.
@MainActor
final class EngineBox {
    var engine: any DictationEngine
    init(_ engine: any DictationEngine) { self.engine = engine }
}

/// Which engine new dictations use, for Settings.
struct EngineStatus: Equatable {
    /// The catalog id, nil for Apple Speech.
    var modelID: String?
    var name = "Apple Speech"
    /// Why Apple Speech is used although a model was picked.
    var fallback: String?
}

/// The last cleanup run's report, for Settings.
@MainActor @Observable
final class CleanupReports {
    private(set) var last: CleanupRunReport?
    func record(_ report: CleanupRunReport) { last = report }
}
