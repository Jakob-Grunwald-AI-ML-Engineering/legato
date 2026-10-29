/// Horizontal cursor tracking for a touch that began on Space. The UI owns the 400 ms timer.
public struct SpaceCursorPan: Sendable {
    /// Transient text window captured once for a pan; hosts may report old context after cursor moves.
    public struct Session: Sendable {
        private var before: String
        private var after: String

        public init(before: String, after: String) {
            self.before = before
            self.after = after
        }

        public mutating func move(by steps: Int) -> Int {
            if steps < 0 {
                let moved = String(before.suffix(-steps))
                before.removeLast(moved.count)
                after = moved + after
                return -moved.utf16.count
            }
            let moved = String(after.prefix(steps))
            after.removeFirst(moved.count)
            before += moved
            return moved.utf16.count
        }
    }

    public private(set) var isActive = false
    private var armed = false
    private var x = 0.0
    private var residual = 0.0

    public init() {}

    public mutating func begin(onSpace: Bool, x: Double) {
        self = Self()
        armed = onSpace
        self.x = x
    }

    /// Starts at the finger's current position, so movement during the hold never jumps the cursor.
    public mutating func activate() -> Bool {
        guard armed, !isActive else { return false }
        isActive = true
        armed = false
        residual = 0
        return true
    }

    public mutating func move(to x: Double) -> Int {
        defer { self.x = x }
        guard isActive else { return 0 }
        residual += x - self.x
        let units = residual / 8
        // UIKit coordinate conversion can leave a completed step infinitesimally below its boundary.
        let nearest = units.rounded()
        let steps = Int(abs(units - nearest) < 1e-9 ? nearest : units)
        residual -= Double(steps) * 8
        return steps
    }

    /// A touch that left Space cannot arm again merely by sliding back over it.
    public mutating func cancelArming() { armed = false }

    /// Whether this release belongs to cursor control and must never insert a space.
    public mutating func finish() -> Bool {
        let consumed = isActive
        self = Self()
        return consumed
    }
}
