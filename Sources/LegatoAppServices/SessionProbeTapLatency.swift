import Foundation

/// Mic tap → first live tail, per tap. The keyboard stamps the tap; the host converts it to its own
/// uptime clock. `warm` says whether a pre-opened stream carried the take, `idleS` how long it had waited.
public struct TapLatencyProbe: Sendable {
    public struct Result: Sendable, Codable, Equatable {
        public var route: AudioRoute
        public var warm: Bool
        public var idleS: Double?
        public var tapToGateMs: Int
        public var tapToAudioMs: Int?
        public var tapToTailMs: Int
        public var fields: [String: Any] {
            var value: [String: Any] = ["route": route.rawValue, "warm": warm, "tapToGateMs": tapToGateMs, "tapToTailMs": tapToTailMs]
            if let idleS { value["idleS"] = (idleS * 10).rounded() / 10 }
            if let tapToAudioMs { value["tapToAudioMs"] = tapToAudioMs }
            return value
        }
    }
    private struct Pending { var route: AudioRoute; var tap: Double; var warm: Bool; var idleS: Double?; var gate: Double?; var audio: Double? }
    private var pending: Pending?
    public init() {}

    public mutating func tapped(route: AudioRoute, at tap: Double, warm: Bool, idleS: Double?) {
        pending = .init(route: route, tap: tap, warm: warm, idleS: idleS)
    }
    public mutating func gateOpened(at time: Double) {
        guard var current = pending, current.gate == nil else { return }
        current.gate = time; pending = current
    }
    public mutating func audioRouted(at time: Double) {
        guard var current = pending, current.gate != nil, current.audio == nil else { return }
        current.audio = time; pending = current
    }
    /// The first nonempty tail on the tapped route completes the measurement, once.
    public mutating func tail(_ text: String, route: AudioRoute, at time: Double) -> Result? {
        guard let current = pending, current.route == route, let gate = current.gate,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        pending = nil
        func ms(_ end: Double) -> Int { Int((max(0, end - current.tap) * 1000).rounded()) }
        return .init(route: route, warm: current.warm, idleS: current.idleS, tapToGateMs: ms(gate),
                     tapToAudioMs: current.audio.map(ms), tapToTailMs: ms(time))
    }
    public mutating func cancel() { pending = nil }
}
