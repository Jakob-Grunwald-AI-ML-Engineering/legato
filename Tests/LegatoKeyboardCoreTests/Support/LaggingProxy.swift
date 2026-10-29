import Foundation
import LegatoFieldEdit
@testable import LegatoKeyboardCore

/// A `textDocumentProxy` whose reads lag: every call changes the field at once, but the context it reports is
/// the field as it was after some earlier call, until the test delivers the later states one by one (each call's
/// state in order: after a move, after each deleted Character, after an insert), as the host's asynchronous
/// context updates do. `drops` loses the calls instead (a write that never reaches the field).
@MainActor
final class LaggingProxy: FieldEditDocument {
    private(set) var field: CaretProxy
    /// The states the host has not reported yet, oldest first.
    private(set) var undelivered: [CaretProxy] = []
    private var reported: CaretProxy
    var documentID: String? = "lagging"
    var drops = false
    private(set) var callCount = 0

    init(_ text: String, caret: Int? = nil) {
        field = CaretProxy(text, caret: caret)
        reported = field
    }

    var contextBefore: String { reported.before }
    var contextAfter: String { reported.after }
    var text: String { field.text }

    func execute(_ calls: [ProxyCall]) {
        callCount += calls.count
        guard !drops else { return }
        for call in calls {
            switch call {
            case .deleteBackward(let count):
                for _ in 0..<count {
                    field.run([.deleteBackward(1)])
                    undelivered.append(field)
                }
            default:
                field.run([call])
                undelivered.append(field)
            }
        }
    }

    /// The host reports the next state; false when it has reported them all.
    @discardableResult
    func deliverNext() -> Bool {
        guard !undelivered.isEmpty else { return false }
        reported = undelivered.removeFirst()
        return true
    }

    func deliverAll() {
        while deliverNext() {}
    }

    /// The user moves the caret (the host reports it at once, after everything before it).
    func moveCaret(to caret: Int) {
        deliverAll()
        field.caret = caret
        reported = field
    }
}

/// Timers on a clock the test moves.
@MainActor
final class ManualTimers {
    private struct Timer {
        var id: Int
        var due: Duration
        var action: @MainActor () -> Void
    }

    private var now: Duration = .zero
    private var timers: [Timer] = []
    private var nextID = 0

    var schedule: FieldEditCoordinator.Schedule {
        { [unowned self] delay, action in
            nextID += 1
            let id = nextID
            timers.append(Timer(id: id, due: now + delay, action: action))
            return { [weak self] in self?.timers.removeAll { $0.id == id } }
        }
    }

    var armed: Int { timers.count }

    /// The test's clock, for a coordinator's `now`.
    var clock: @MainActor () -> Duration { { [unowned self] in now } }

    /// Moves the clock on, firing every timer due on the way, in order.
    func advance(by delta: Duration) {
        let end = now + delta
        while let next = timers.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            now = next.due
            next.action()
        }
        now = end
    }
}

extension LaggingProxy {
    /// The host empties the field (a chat app sends it); like every change, its report lags.
    func hostClears() {
        field = CaretProxy("")
        undelivered.append(field)
    }
}
