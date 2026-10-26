import Foundation

/// How long a mic lease outlives a run, so the next run starts without activating the audio session again.
public enum Linger: Sendable, Hashable {
    /// Released as soon as the run ends.
    case off
    /// Released this long after the run ends, unless a new run starts first (each run restarts the whole time).
    case duration(Duration)
    /// Never expires on its own: held until it is ended explicitly (`endLease`, `endKeepAlive`), a system
    /// event takes the mic, or a start finds it dead.
    case indefinite

    /// Alias of `.off`, for call sites that read as "no linger".
    public static let zero = Linger.off

    /// `.off` for zero or less.
    public static func seconds(_ seconds: Int) -> Linger {
        seconds > 0 ? .duration(.seconds(seconds)) : .off
    }

    /// The lease outlives the run, for a while or for good.
    public var holdsLease: Bool { self != .off }

    /// How long the lease lives after a run; nil for `.off` and `.indefinite` (no timer).
    public var timeout: Duration? {
        if case .duration(let d) = self { return d }
        return nil
    }
}

/// The "keep microphone ready" choices a user picks from, as stored seconds (`-1`: indefinitely).
public enum KeepAliveChoice: Int, CaseIterable, Sendable {
    case off = 0
    case minute1 = 60
    case minutes5 = 300
    case minutes10 = 600
    case minutes30 = 1800
    case hour1 = 3600
    case indefinitely = -1

    public var linger: Linger {
        switch self {
        case .off: .off
        case .indefinitely: .indefinite
        default: .seconds(rawValue)
        }
    }

    /// Maps a value stored by an earlier version (30 s and 2 min were offered then) or by hand to a
    /// current choice: 30 to 1 minute, 120 to 5 minutes, negative to indefinitely, zero to off, anything
    /// else to the nearest choice (a tie goes to the longer).
    public init(migratingStoredSeconds seconds: Int) {
        if seconds < 0 {
            self = .indefinitely
        } else if seconds == 0 {
            self = .off
        } else if let exact = Self(rawValue: seconds) {
            self = exact
        } else if seconds == 30 {
            self = .minute1
        } else if seconds == 120 {
            self = .minutes5
        } else {
            let timed = Self.allCases.filter { $0.rawValue > 0 }
            // The nearest choice; on a tie the longer one (`min` keeps the first of equals, so sort longest first).
            self = timed.sorted { $0.rawValue > $1.rawValue }
                .min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) } ?? .minute1
        }
    }
}
