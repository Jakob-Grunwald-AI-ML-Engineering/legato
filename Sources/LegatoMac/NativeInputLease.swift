import Foundation

/// Admission and failure policy for one native cursor borrow. Event storage is separate:
/// retaining an old event never grants permission to capture new input after failure.
public struct NativeInputLease: Sendable {
    public enum Phase: String, Sendable { case idle, borrowed, replaying, blocked }
    public private(set) var phase = Phase.idle
    public init() {}
    public var canBegin: Bool { phase == .idle }
    public var capturesInput: Bool { phase == .borrowed || phase == .replaying }
    @discardableResult public mutating func begin() -> Bool {
        guard canBegin else { return false }
        phase = .borrowed
        return true
    }
    public mutating func finish(homeVerified: Bool, hasPendingEvents: Bool) {
        guard phase == .borrowed else { return }
        phase = homeVerified ? (hasPendingEvents ? .replaying : .idle) : .blocked
    }
    public mutating func drained() {
        if phase == .replaying { phase = .idle }
    }
    public mutating func disable(hasPendingEvents: Bool) {
        if phase != .idle || hasPendingEvents { phase = .blocked }
    }
    /// The adapter must independently confirm a new explicit click, the original
    /// nonsecure field and a stable caret before releasing events retained at failure.
    @discardableResult public mutating func recover(verifiedClick: Bool, hasPendingEvents: Bool) -> Bool {
        guard phase == .blocked, verifiedClick else { return false }
        phase = hasPendingEvents ? .replaying : .idle
        return true
    }
}
