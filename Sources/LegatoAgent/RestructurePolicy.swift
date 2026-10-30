import Foundation

public struct RestructurePolicy: Sendable {
    public private(set) var segments = 0
    public private(set) var running = false
    public private(set) var finalPending = false
    public private(set) var requested = false
    private var lastSegment: Double = 0
    public init() {}
    public mutating func segment(at time: Double) { segments += 1; lastSegment = time }
    public mutating func request() { requested = true }
    public mutating func finalPass() { finalPending = true }
    public mutating func begin(at time: Double) -> Bool? {
        guard !running, finalPending || requested || segments >= 4 || (segments >= 2 && time - lastSegment >= 2.5) else { return nil }
        let final = finalPending; running = true; segments = 0; requested = false; finalPending = false; return final
    }
    public mutating func finish() { running = false }
}
