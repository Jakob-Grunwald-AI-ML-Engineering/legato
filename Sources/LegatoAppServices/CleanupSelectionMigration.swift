import Foundation
import LegatoCoreML
import LegatoModels

/// Converts preferences once without touching weights, starting work, or changing unrelated settings.
enum CleanupSelectionMigration {
    private static let marker = "cleanup.coreMLSelectionMigrated.v1"
    static func migrate(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: marker) else { return }
        let selection = SelectionStore(defaults: defaults)
        let oldID = selection.selected(for: .cleanup)
        let replacements = [
            "mlx-qwen3-0.6b-4bit": CoreMLModels.qwen3_0_6bID,
            "mlx-qwen3-1.7b-4bit": CoreMLModels.qwen3_1_7bID,
            "mlx-gemma3-1b-4bit": CoreMLModels.gemma3_1bID
        ]
        for key in ["cleanup.backend", "meeting.summaryBackend"] {
            let raw = defaults.string(forKey: key) ?? "auto"
            let choice: CleanupBackendChoice
            switch raw {
            case "foundationModels": choice = .foundationModels
            case "auto": choice = oldID == nil ? .foundationModels : .coreML
            default: choice = .coreML // Explicit local or unresolved intent never substitutes a family.
            }
            defaults.set(choice.rawValue, forKey: key)
        }
        if let oldID, let replacement = replacements[oldID] { selection.set(replacement, for: .cleanup) }
        defaults.set(true, forKey: marker)
    }
}
