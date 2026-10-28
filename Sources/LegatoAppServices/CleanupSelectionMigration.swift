import Foundation
import LegatoCoreML
import LegatoModels

/// Discards unsupported old choices once; valid new choices and unrelated settings stay intact.
enum CleanupSelectionMigration {
    private static let marker = "cleanup.coreMLSelectionMigrated.v1"
    static func migrate(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: marker) else { return }
        for key in ["cleanup.backend", "meeting.summaryBackend"] {
            if defaults.string(forKey: key).flatMap(CleanupBackendChoice.init(rawValue:)) == nil {
                defaults.set(CleanupBackendChoice.foundationModels.rawValue, forKey: key)
            }
        }
        let selection = SelectionStore(defaults: defaults)
        if let id = selection.selected(for: .cleanup), CoreMLModels.spec(id: id) == nil {
            selection.set(nil, for: .cleanup)
        }
        defaults.set(true, forKey: marker)
    }
}
