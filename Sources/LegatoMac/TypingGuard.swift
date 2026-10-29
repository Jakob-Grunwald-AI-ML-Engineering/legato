import Foundation
import LegatoFieldEdit

/// Reports that something changed in the field's value or selection (on macOS: Accessibility's value-changed and
/// selected-text-changed notifications). The guard cannot tell the user from our own writes by itself; see
/// ``TypingGuard/isEcho``.
@MainActor
public protocol FieldActivitySource: AnyObject {
    /// Starts reporting to `handler`; false when it could not (the guard then sees no typing and holds nothing).
    @discardableResult
    func start(_ handler: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

/// Physical keys go to the host app, not to us, so on the Mac they cannot be queued. The guard instead marks user
/// activity and tells the executor how long a non-user write must wait: until the field has been quiet for
/// ``defaultQuiet``. User commands (``EditOrigin/isUser``) are never held.
@MainActor
public final class TypingGuard {
    public static let defaultQuiet: TimeInterval = 0.3

    private let source: (any FieldActivitySource)?
    private let quiet: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private var lastActivity: TimeInterval?
    private var stopped = false

    /// Whether the source reports activity. False when it failed to start (the guard fails open: non-user
    /// writes are never held, every write is still checked by readback) or after ``stop()``.
    public private(set) var isWatching = false

    /// Whether the change just reported is only our own write showing up (the field reads as the queue left
    /// it). Echoes are not user activity. Set by the executor; nil counts every notification.
    public var isEcho: (@MainActor () -> Bool)?

    public init(
        source: (any FieldActivitySource)? = nil, quiet: TimeInterval = TypingGuard.defaultQuiet,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.source = source
        self.quiet = quiet
        self.now = now
        isWatching = source?.start { [weak self] in self?.fieldChanged() } ?? false
    }

    /// Marks user activity now.
    public func noteUserActivity() { lastActivity = now() }

    /// How long a write from `origin` has to wait: 0 means it may run now.
    public func delay(for origin: EditOrigin) -> TimeInterval {
        guard !origin.isUser, let lastActivity else { return 0 }
        return max(0, quiet - (now() - lastActivity))
    }

    /// Detaches from the source; a notification still on its way after this is ignored.
    public func stop() {
        stopped = true
        isWatching = false
        source?.stop()
    }

    private func fieldChanged() {
        if stopped || isEcho?() == true { return }
        noteUserActivity()
    }
}
