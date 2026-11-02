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
    /// Every take, short or long, is typed out over this long: the pace adapts to the length.
    public static let duration = Duration.milliseconds(300)
    /// Most steps one take is cut into (about 10 ms apart); longer texts group several words per step.
    public static let maxSteps = 30
    /// Most UTF-16 units one synthetic key event carries.
    public static let eventUnits = 20

    /// Word-sized steps: each word with the whitespace that follows it, in order, joined back to the exact text.
    /// Long texts group several words per step so there are at most `maxSteps`.
    public static func steps(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            if character.isWhitespace {
                inSpace = true
            } else if inSpace {
                words.append(current); current = ""; inSpace = false
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        guard words.count > maxSteps else { return words }
        let group = (words.count + maxSteps - 1) / maxSteps
        return stride(from: 0, to: words.count, by: group).map { words[$0..<min($0 + group, words.count)].joined() }
    }

    /// The pause between steps, so the first step lands at once and the last one `duration` later.
    public static func interval(steps: Int) -> Duration {
        guard steps > 1 else { return .zero }
        return duration / (steps - 1)
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

    /// Whether a text must go by paste: a synthetic Return or Tab would send a message or move the focus.
    public static func needsPaste(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" }
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
            guard write(step) else {
                return Result(remainder: steps[index...].joined(), wroteAny: wrote)
            }
            wrote = true
        }
        return Result(remainder: nil, wroteAny: wrote)
    }
}
