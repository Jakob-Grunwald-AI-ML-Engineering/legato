import Foundation
import LegatoCore
import LegatoModels

/// Decides when a silence is long enough to commit the current segment.
///
/// Judges whole chunks by RMS (as the spike does), so a lone click inside a silent chunk counts the whole
/// chunk as speech. Pure: it never touches a model.
struct SilenceEndpointer: Sendable {
    /// Consecutive silent samples that end a segment (1200 ms at 16 kHz is 19,200).
    let silenceSamples: Int
    let rmsThreshold: Float
    private var silent = 0
    /// Whether any non-silent chunk arrived since the last commit or reset.
    private(set) var heardSpeech = false

    init(sampleRate: Int = 16_000, silenceMs: Int = 1200, rmsThreshold: Float = 0.004) {
        self.silenceSamples = sampleRate * silenceMs / 1000
        self.rmsThreshold = rmsThreshold
    }

    /// Feeds the next chunk and returns whether the segment should be committed now: the silent run has
    /// reached ``silenceSamples`` and there is text to commit. A commit starts a fresh run.
    mutating func feed(_ samples: [Float], hasText: Bool) -> Bool {
        guard !samples.isEmpty else { return false }
        var sum = 0.0
        for sample in samples { sum += Double(sample * sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        if rms < Double(rmsThreshold) {
            silent += samples.count
        } else {
            silent = 0
            heardSpeech = true
        }
        guard hasText, silent >= silenceSamples else { return false }
        reset()
        return true
    }

    mutating func reset() {
        silent = 0
        heardSpeech = false
    }
}

/// Turns a model's cumulative partial text and its segment text into ``TranscriptEvent``s.
///
/// Partials become volatile events (only when they change); a commit becomes a final event with a range
/// and clears the shown partial. ``TranscriptAssembler`` appends final text verbatim, so later text gets
/// the separating space here.
struct PartialEventMapper: Sendable {
    let stream: TranscriptEvent.Stream
    private var shown = ""
    private var committedEndsWithSpace = true  // true while nothing is committed

    init(stream: TranscriptEvent.Stream = .mic) {
        self.stream = stream
    }

    /// The volatile event for a new partial, or `nil` when it matches what is already shown.
    mutating func partial(_ text: String) -> TranscriptEvent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != shown else { return nil }
        shown = trimmed
        return TranscriptEvent(stream: stream, text: spaced(trimmed), isFinal: false)
    }

    /// The events for a finished segment: its final event (when it has text), then a clear of the shown partial.
    mutating func commit(_ text: String, range: Range<TimeInterval>?) -> [TranscriptEvent] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var events: [TranscriptEvent] = []
        if !trimmed.isEmpty {
            events.append(TranscriptEvent(stream: stream, text: spaced(trimmed), isFinal: true, range: range))
            committedEndsWithSpace = false
        }
        if !shown.isEmpty {
            events.append(TranscriptEvent(stream: stream, text: "", isFinal: false))
        }
        shown = ""
        return events
    }

    private func spaced(_ text: String) -> String {
        text.isEmpty || committedEndsWithSpace ? text : " " + text
    }
}

/// Which Nemotron language hint a session runs on, and when to narrow it.
///
/// Nemotron takes one prompt id per run, so several preferred locales run on `auto`. When the detected
/// language falls outside the set, the first preferred locale is pinned at the next segment boundary,
/// and `auto` returns at the next session.
struct LanguageClamp: Sendable {
    private let preferred: [Locale]
    private(set) var hint: String
    private var pendingPin = false
    private var pinned = false

    init(preferred: [Locale]) {
        self.preferred = preferred
        self.hint = Self.initialHint(preferred)
    }

    /// The locales a session expects: the configured set, or the session's locale when none is configured.
    static func preferred(configured: [Locale], session: Locale?) -> [Locale] {
        if !configured.isEmpty { return configured }
        return session.map { [$0] } ?? []
    }

    /// The locale a FluidAudio language tag such as "en-US" or "es-419" names.
    static func locale(fromTag tag: String) -> Locale {
        Locale(identifier: tag.replacingOccurrences(of: "-", with: "_"))
    }

    /// Notes the language the model reports detecting; schedules a pin if it is not a preferred one.
    mutating func observe(detected: String?) {
        guard preferred.count > 1, !pinned, let detected else { return }
        let language = Self.locale(fromTag: detected).language.languageCode?.identifier
        let wanted = preferred.compactMap { $0.language.languageCode?.identifier }
        if let language, !wanted.contains(language) { pendingPin = true }
    }

    /// Call between segments: the hint to apply to the model now, if a pin is due.
    mutating func segmentBoundary() -> String? {
        guard pendingPin, let first = preferred.first else { return nil }
        pendingPin = false
        pinned = true
        hint = Self.tag(for: first)
        return hint
    }

    /// A new session starts on the initial hint again.
    mutating func beginSession() {
        hint = Self.initialHint(preferred)
        pendingPin = false
        pinned = false
    }

    private static func initialHint(_ preferred: [Locale]) -> String {
        preferred.count == 1 ? tag(for: preferred[0]) : "auto"
    }

    private static func tag(for locale: Locale) -> String {
        locale.identifier(.bcp47)
    }
}

/// Maps a ``ModelManager`` install state to the `0...1` progress `DictationEngine.installAssets` reports.
enum InstallProgress {
    /// The download fills most of the bar, then the first Neural Engine compile, then done.
    static func fraction(for state: ModelState) -> Double? {
        switch state {
        case .downloading(let fraction): min(max(fraction, 0), 1) * 0.9
        case .warming: 0.95
        case .installed: 1
        case .notInstalled, .failed: nil
        }
    }
}

/// One decoded piece of text with its time span. SentencePiece word starts carry a leading "▁" or a space.
struct TimedToken: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Groups timed tokens into sentence-sized final events for the batch transcribers.
///
/// A segment ends after `.`, `?` or `!` (unless the mark sits inside a word, as in "3.5") and wherever the
/// silence between two tokens is longer than `maxGap`. Ranges are clamped so they never overlap: each
/// starts no earlier than the previous one ended.
enum SegmentGrouper {
    /// The silence, in seconds, that starts a new segment.
    static let maxGap: TimeInterval = 0.8

    private static let wordBoundary = "\u{2581}"  // "▁"
    private static let sentenceEnds: Set<Character> = [".", "?", "!"]
    private static let skipped: Set<String> = ["", "<blank>", "<pad>"]

    private struct Piece {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var startsWord: Bool { text.first?.isWhitespace ?? false }
    }

    static func group(
        _ tokens: [TimedToken], stream: TranscriptEvent.Stream = .mic, maxGap: TimeInterval = SegmentGrouper.maxGap
    ) -> [TranscriptEvent] {
        let pieces: [Piece] = tokens.compactMap { token in
            guard !skipped.contains(token.text) else { return nil }
            let text = token.text.replacingOccurrences(of: wordBoundary, with: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return Piece(text: text, start: token.start, end: token.end)
        }

        var events: [TranscriptEvent] = []
        var current: [Piece] = []
        var previousEnd = -TimeInterval.infinity

        func flush() {
            defer { current = [] }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = current.first, let last = current.last, !text.isEmpty else { return }
            let start = max(first.start, previousEnd)
            let end = max(last.end, start)
            previousEnd = end
            events.append(TranscriptEvent(stream: stream, text: text, isFinal: true, range: start..<end))
        }

        for (index, piece) in pieces.enumerated() {
            if let last = current.last, piece.start - last.end > maxGap { flush() }
            current.append(piece)
            let endsSentence = piece.text.trimmingCharacters(in: .whitespaces).last.map(sentenceEnds.contains) ?? false
            let nextStartsWord = index + 1 >= pieces.count || pieces[index + 1].startsWord
            if endsSentence && nextStartsWord { flush() }
        }
        flush()
        return events
    }
}
