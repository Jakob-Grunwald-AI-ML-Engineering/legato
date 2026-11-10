import Foundation

/// Marks every key event Legato synthesizes (`eventSourceUserData`), so the hotkey tap never mistakes them for
/// the user's keys.
public enum SyntheticEvent {
    /// "LEGATO" in ASCII.
    public static let userData: Int64 = 0x4C45_4741_544F
    public static func isLegato(_ userData: Int64) -> Bool { userData == Self.userData }
}

/// Cuts a dictated text into the steps a typewriter writes and sets the pace. Pure.
public enum TypewriterPlan {
    /// A take that arrives whole (line-by-line dictation, composer inserts) is typed out over this long; a
    /// streaming take is paced by `drainStep` instead.
    public static let duration = Duration.milliseconds(300)
    /// Most UTF-16 units one synthetic key event carries.
    public static let eventUnits = 20

    /// Each visible step is exactly one extended grapheme cluster, even for long text.
    public static func steps(_ text: String) -> [String] { text.map(String.init) }

    /// Time constant of the streaming drain (the same as the keyboard's `TypewriterDrain`): each frame types the
    /// share of the pending text that empties it over about this long, so the typing never lags far behind.
    public static let drainWindowMs = 250.0

    /// Characters shown after a frame of `dtMs` when `revealed` of `target` are: at least one more, never past `target`.
    public static func drainStep(revealed: Int, target: Int, dtMs: Double) -> Int {
        guard revealed < target else { return target }
        let slice = max(1, Int((Double(target - revealed) * dtMs / drainWindowMs).rounded(.up)))
        return min(target, revealed + slice)
    }

    /// The pause between steps, so the first step lands at once and the last one `duration` later.
    public static func interval(steps: Int) -> Duration {
        guard steps > 1 else { return .zero }
        return max(.milliseconds(20), duration / (steps - 1))
    }

    /// Pieces of at most `eventUnits` UTF-16 units, cut on grapheme boundaries (a grapheme longer than the
    /// limit, such as a long emoji sequence, is cut on scalars as a last resort).
    public static func eventChunks(_ text: String, maxUnits: Int = eventUnits) -> [String] {
        var chunks: [String] = []
        var current = ""
        var units = 0
        func flush() { if !current.isEmpty { chunks.append(current); current = ""; units = 0 } }
        for character in text {
            let size = character.utf16.count
            if size > maxUnits {
                flush()
                var piece = ""
                for scalar in character.unicodeScalars {
                    if piece.utf16.count + scalar.utf16.count > maxUnits { chunks.append(piece); piece = "" }
                    piece.unicodeScalars.append(scalar)
                }
                if !piece.isEmpty { chunks.append(piece) }
                continue
            }
            if units + size > maxUnits { flush() }
            current.append(character); units += size
        }
        flush()
        return chunks
    }

    /// Controls must not synthesize Return/Tab, and a grapheme larger than a key event must stay intact.
    public static func needsPaste(_ text: String) -> Bool {
        text.contains { $0.utf16.count > eventUnits } || text.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }
}

/// Runs a typewriter: one step at a time, a pause between steps, stopping at the first step that cannot be written.
public enum Typewriter {
    public struct Result: Sendable, Equatable {
        /// The text that was not written (the failed step and everything after it); nil when all was written.
        public var remainder: String?
        /// At least one step was written.
        public var wroteAny: Bool
    }

    /// `write` returns false when the step could not be written (the typewriter stops there). `sleep` is injected
    /// so tests run on a virtual clock. With `clock`, each pause is shortened by the time the writes took, so a
    /// slow field still finishes on schedule (a field slower than the schedule just writes back to back).
    @MainActor
    public static func run(_ text: String, sleep: (Duration) async -> Void, clock: ContinuousClock? = nil,
                           write: @MainActor (String) -> Bool) async -> Result {
        await run(text, sleep: sleep, clock: clock, writeAsync: { write($0) })
    }

    /// Async writes let a host safely consume an individual control character through its
    /// clipboard interface while keeping every other character on the same paced sequence.
    @MainActor
    public static func run(_ text: String, sleep: (Duration) async -> Void, clock: ContinuousClock? = nil,
                           writeAsync: @MainActor (String) async -> Bool) async -> Result {
        let steps = TypewriterPlan.steps(text)
        let interval = TypewriterPlan.interval(steps: steps.count)
        let start = clock?.now
        var wrote = false
        for (index, step) in steps.enumerated() {
            if index > 0 {
                var pause = interval
                if let clock, let start { pause = max(.zero, interval * index - start.duration(to: clock.now)) }
                if pause > .zero { await sleep(pause) }
            }
            guard !Task.isCancelled, await writeAsync(step) else {
                return Result(remainder: steps[index...].joined(), wroteAny: wrote)
            }
            wrote = true
        }
        return Result(remainder: nil, wroteAny: wrote)
    }
}
