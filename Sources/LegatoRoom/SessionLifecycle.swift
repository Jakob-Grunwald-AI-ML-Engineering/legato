public enum SessionState: String, Codable, Sendable { case listening, trailing, finalPass, paused, done }

public struct SessionLifecycle: Sendable {
    public private(set) var state: SessionState = .listening
    public private(set) var busyAgents: Set<Participant> = []
    public init() {}
    mutating func setBusy(_ participant: Participant, busy: Bool) {
        guard state != .done else { return }
        if busy { busyAgents.insert(participant) } else { busyAgents.remove(participant) }
    }
    mutating func micOff() { if state == .listening { state = .trailing } }
    mutating func beginFinalPassIfReady() -> Bool {
        guard state == .trailing, busyAgents.isEmpty else { return false }
        state = .finalPass
        return true
    }
    mutating func pause() { state = .paused; busyAgents.removeAll() }
    mutating func resume() { state = .listening }
    mutating func finish() { state = .done; busyAgents.removeAll() }
}
