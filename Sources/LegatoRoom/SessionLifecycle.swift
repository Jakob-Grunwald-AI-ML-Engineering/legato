public enum SessionState: String, Codable, Sendable { case listening, trailing, finalPass, done }

public struct SessionLifecycle: Sendable {
    public private(set) var state: SessionState = .listening
    public init() {}
    mutating func micOff() { if state == .listening { state = .trailing } }
    mutating func beginFinalPassIfReady() -> Bool {
        guard state == .trailing else { return false }
        state = .finalPass
        return true
    }
    mutating func finish() { state = .done }
}
