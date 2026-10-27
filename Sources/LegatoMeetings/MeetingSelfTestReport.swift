import Foundation

/// What the Mac meeting self-test writes: how much each stream heard, and its text only on request.
///
/// The report carries character and word counts by default, enough to tell a dead system-audio tap from a
/// working one, so a report left in a temporary folder never holds what was said. The transcript text is
/// added only when the run was started with `--meeting-selftest-text`.
public struct MeetingSelfTestReport: Codable, Sendable, Equatable {
    public var seconds: Double
    public var engine: String
    public var engineFallback: String?
    public var tapStatus: String?
    public var meChars: Int
    public var meWords: Int
    public var meSegments: Int
    public var themChars: Int
    public var themWords: Int
    public var themSegments: Int
    public var themTapZeroRatio: Double?
    public var themTapBuffers: Int
    public var note: String?
    /// Only with ``init(seconds:engine:engineFallback:tapStatus:segments:themTapZeroRatio:themTapBuffers:includeText:)`` `includeText`.
    public var meText: String?
    public var themText: String?

    /// A run that could not start.
    public init(seconds: Double, failure: String) {
        self.seconds = seconds
        engine = ""
        meChars = 0
        meWords = 0
        meSegments = 0
        themChars = 0
        themWords = 0
        themSegments = 0
        themTapBuffers = 0
        note = failure
    }

    /// - Parameters:
    ///   - segments: everything the meeting saved; echoes of "them" in the mic stream are left out of "me".
    ///   - includeText: put the transcript text in the report.
    public init(
        seconds: Double, engine: String, engineFallback: String?, tapStatus: String?, segments: [MeetingSegment],
        themTapZeroRatio: Double?, themTapBuffers: Int, includeText: Bool
    ) {
        let me = segments.filter { $0.stream == .mic && !$0.echo }.map(\.text).joined(separator: " ")
        let them = segments.filter { $0.stream == .system }.map(\.text).joined(separator: " ")
        self.seconds = seconds
        self.engine = engine
        self.engineFallback = engineFallback
        self.tapStatus = tapStatus
        meChars = me.count
        meWords = Self.words(me)
        meSegments = segments.filter { $0.stream == .mic && !$0.echo }.count
        themChars = them.count
        themWords = Self.words(them)
        themSegments = segments.filter { $0.stream == .system }.count
        self.themTapZeroRatio = themTapZeroRatio
        self.themTapBuffers = themTapBuffers
        note = themSegments == 0
            ? "them is empty: nothing played, or System Audio Recording is not granted to Legato."
            : nil
        if includeText {
            meText = me
            themText = them
        }
    }

    /// Whether "them" heard something: what the self-test's exit code is about.
    public var themHeardSomething: Bool { themWords > 0 }

    private static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
