import Foundation
import LegatoFieldEdit

/// Reports that something changed in the field's value or selection (on macOS: Accessibility's value-changed and
/// selected-text-changed notifications). The guard cannot tell the user from our own writes by itself; see
/// ``TypingGuard/isEcho``.
@MainActor
public protocol FieldActivitySource: AnyObject {
    func start(_ handler: @escaping @MainActor () -> Void)
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
        source?.start { [weak self] in self?.fieldChanged() }
    }

    /// Marks user activity now.
    public func noteUserActivity() { lastActivity = now() }

    /// How long a write from `origin` has to wait: 0 means it may run now.
    public func delay(for origin: EditOrigin) -> TimeInterval {
        guard !origin.isUser, let lastActivity else { return 0 }
        return max(0, quiet - (now() - lastActivity))
    }

    public func stop() { source?.stop() }

    private func fieldChanged() {
        if isEcho?() == true { return }
        noteUserActivity()
    }
}
