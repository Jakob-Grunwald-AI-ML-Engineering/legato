import Foundation

/// A conservative correction gate, not a voice detector. An acoustic quiet window alone never
/// releases edits: a semantic endpoint must arrive during it. Calibrated on the 13 recorded
/// takes in docs/plan/field-cleanup-measurements.md; not validated across speakers/noisy rooms.
public struct DictationActivity: Sendable {
    public enum State: String, Sendable { case speaking, paused }
    public private(set) var state = State.speaking
    public private(set) var quietSeconds = 0.0
    public static let quietDBFS = -55.0
    public static let quietWindowSeconds = 0.2
    private var frame: [Int16] = []
    private static let frameSamples = 320 // 20 ms at the capture contract's 16 kHz.

    public init() {}

    /// Consume original 16 kHz mono signed little-endian PCM before network buffering. Every
    /// nonquiet frame revokes permission immediately, even if recognition has not caught up.
    @discardableResult public mutating func receive(_ pcm: Data) -> Bool {
        var heardActivity = false
        let bytes = Array(pcm)
        var i = 0
        while i + 1 < bytes.count {
            frame.append(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
            i += 2
            if frame.count == Self.frameSamples {
                let energy = frame.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame.count)
                let level = energy == 0 ? -Double.infinity : 10 * log10(energy / (32768 * 32768))
                if level > Self.quietDBFS {
                    quietSeconds = 0; state = .speaking; heardActivity = true
                } else { quietSeconds += Double(Self.frameSamples) / 16_000 }
                frame.removeAll(keepingCapacity: true)
            }
        }
        return heardActivity
    }

    @discardableResult public mutating func boundary(_ reason: String) -> Bool {
        guard reason == "endpoint", quietSeconds + 0.000_001 >= Self.quietWindowSeconds else { return false }
        state = .paused
        return true
    }
}
