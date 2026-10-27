import ActivityKit
import Foundation

struct SpikeRecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: String
    }
    var runID: String
}
