import Foundation
import LegatoRoom
import LegatoComposerDoc

public struct LiveAgentPolicy: Sendable {
    public private(set) var pending: [Envelope] = []
    public private(set) var running = false
    private var active: [Envelope] = []
    public var editing: Set<String> = []
    public init() {}
    @discardableResult public mutating func enqueue(_ event: Envelope, hintTargets: Set<String> = []) -> Bool {
        guard [.hint, .userIntent].contains(event.channel) || AgentAdmission.isAcceptedContent(event) else { return false }
        let preempt = running && event.channel == .hint && !editing.isDisjoint(with: hintTargets)
        if preempt { pending = active + pending }
        if event.channel == .hint { pending.insert(event, at: 0) } else { pending.append(event) }
        return preempt
    }
    public mutating func begin() -> [Envelope]? {
        guard !running, !pending.isEmpty else { return nil }; running = true
        active = pending; defer { pending = []; editing = [] }; return pending
    }
    public mutating func beginMaintenance() -> Bool {
        guard !running, pending.isEmpty else { return false }
        running = true; active = []; editing = []; return true
    }
    public mutating func finish() { running = false; editing = []; active = [] }
}

/// Raw ASR remains context, but only a binder-accepted append admits a content turn.
enum AgentAdmission {
    static func isAcceptedContent(_ event: Envelope) -> Bool {
        event.channel == .docOps && (try? event.payload.decode(Transaction.self).origin) == .asr
    }
}
