import Foundation
import LegatoRoom

public struct LiveAgentPolicy: Sendable {
    public private(set) var pending: [Envelope] = []
    public private(set) var running = false
    private var active: [Envelope] = []
    public var editing: Set<String> = []
    public init() {}
    @discardableResult public mutating func enqueue(_ event: Envelope, hintTargets: Set<String> = []) -> Bool {
        guard [.asrSegment, .hint, .userIntent].contains(event.channel) else { return false }
        let preempt = running && event.channel == .hint && !editing.isDisjoint(with: hintTargets)
        if preempt { pending = active + pending }
        if event.channel == .hint { pending.insert(event, at: 0) } else { pending.append(event) }
        return preempt
    }
    public mutating func begin() -> [Envelope]? {
        guard !running, !pending.isEmpty else { return nil }; running = true
        active = pending; defer { pending = []; editing = [] }; return pending
    }
    public mutating func finish() { running = false; editing = []; active = [] }
}
