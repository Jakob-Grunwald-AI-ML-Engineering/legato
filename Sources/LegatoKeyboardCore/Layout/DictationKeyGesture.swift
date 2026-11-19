import Foundation

/// What a touch on the dictation key does (#315): a tap starts, pauses or resumes dictation; a swipe down minimises the
/// keyboard, up expands it, left undoes, right redoes. A drag never also taps.
public enum DictationKeyGesture: Sendable, Equatable {
    case tap
    case swipe(Direction)

    public enum Direction: Sendable, Equatable, CaseIterable { case up, down, left, right }

    /// The most a finger may travel and still tap (as the other keys).
    public static let tapSlop = 10.0
    /// The least travel along one axis that is a swipe: an ESTIMATE (as the preview's swipes), to tune on the phone.
    public static let swipeDistance = 20.0
    /// A swipe's axis must be at least this many times the other one; a diagonal drag does nothing.
    public static let dominance = 1.5

    /// The swipe a drag of (`dx`, `dy`) points (y grows downward), nil while it is not one yet.
    public static func swipe(dx: Double, dy: Double) -> Direction? {
        let horizontal = abs(dx), vertical = abs(dy)
        if horizontal >= swipeDistance, horizontal >= dominance * vertical { return dx < 0 ? .left : .right }
        if vertical >= swipeDistance, vertical >= dominance * horizontal { return dy < 0 ? .up : .down }
        return nil
    }
}

/// One touch on the dictation key, from the drag's updates: the swipe fires once, as soon as the drag is one (iOS may cancel
/// a touch near the keyboard's top before the finger lifts), and the lift taps only when no swipe fired and the finger
/// stayed within the tap slop.
public struct DictationKeyDrag: Sendable, Equatable {
    private var start: (x: Double, y: Double)?
    private var fired = false

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fired == rhs.fired && lhs.start?.x == rhs.start?.x && lhs.start?.y == rhs.start?.y
    }

    /// The finger moved: the swipe to perform now, once per touch. A touch after a lift, or from a new start point, is a new
    /// touch (a cancelled one never reported its end).
    public mutating func moved(startX: Double, startY: Double, dx: Double, dy: Double) -> DictationKeyGesture.Direction? {
        if start == nil || start?.x != startX || start?.y != startY { start = (startX, startY); fired = false }
        guard !fired, let direction = DictationKeyGesture.swipe(dx: dx, dy: dy) else { return nil }
        fired = true
        return direction
    }

    /// The finger lifted: a tap, or nothing (a swipe already acted, or the finger wandered).
    public mutating func ended(dx: Double, dy: Double) -> DictationKeyGesture? {
        defer { start = nil }
        guard !fired, hypot(dx, dy) < DictationKeyGesture.tapSlop else { return nil }
        return .tap
    }

    /// Whether the last touch swiped, until the next one begins: the key's link, which acts on the same lift in no fixed
    /// order with `ended`, must not open the app then.
    public var swiped: Bool { fired }
}

/// The faint swipe hints on the dictation key show for its first few uses, then never again. Counted in the keyboard's own
/// defaults (works without Full Access), like the last layout.
public struct DictationKeyHints: Equatable {
    /// How many uses show the hints: an ESTIMATE of "the first few".
    public static let limit = 8
    static let key = "keyboardDictationKeyUses"

    public private(set) var uses: Int
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        uses = defaults?.integer(forKey: Self.key) ?? 0
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.uses == rhs.uses }

    public var shows: Bool { uses < Self.limit }

    /// A tap or a swipe on the key; counting stops at the limit.
    public mutating func noteUse() {
        guard shows else { return }
        uses += 1
        defaults?.set(uses, forKey: Self.key)
    }
}
