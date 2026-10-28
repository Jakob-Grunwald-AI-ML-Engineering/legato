import Foundation

/// This protocol deliberately has no dependency on the production keyboard core or its identifiers.
enum SpikeIDs {
    static let group = "group.de.gruenwald.legato.ane-spike"
    static let requestNote = "de.gruenwald.legato.ane-spike.request"
    static let scheme = "anecleanup39"
    @MainActor static let defaults = UserDefaults(suiteName: group)!
}
struct SpikeRequest: Codable {
    let id: UUID
    let created: Date
    let command: String
    init(command: String) { id = UUID(); created = Date(); self.command = command }
}
struct SpikeResult: Codable {
    let runID: String
    let text: String
    let created: Date
}
