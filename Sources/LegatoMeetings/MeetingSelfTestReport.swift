import Foundation

/// What the Mac meeting self-test writes: how much the mixed transcript holds, and its text only on request.
///
/// The report carries character and word counts by default, enough to tell a dead capture from a working
/// one, so a report left in a temporary folder never holds what was said. The transcript text is added only
/// when the run was started with `--meeting-selftest-text`.
public struct MeetingSelfTestReport: Codable, Sendable, Equatable {
    public var seconds: Double
    public var engine: String
    public var engineFallback: String?
    public var tapStatus: String?
    public var chars: Int
    public var words: Int
    public var segments: Int
    /// How much of the system-audio tap was all zeros (a dead tap is all zeros).
    public var tapZeroRatio: Double?
    public var tapBuffers: Int
    public var note: String?
    /// Only with `includeText`.
    public var text: String?

    /// A run that could not start.
    public init(seconds: Double, failure: String) {
        self.seconds = seconds
        engine = ""
        chars = 0
        words = 0
        segments = 0
        tapBuffers = 0
        note = failure
    }

    /// - Parameters:
    ///   - segments: everything the meeting saved. The mixed transcript is counted whole; echoes (old
    ///     two-stream meetings only) are left out.
    ///   - includeText: put the transcript text in the report.
    public init(
        seconds: Double, engine: String, engineFallback: String?, tapStatus: String?, segments: [MeetingSegment],
        tapZeroRatio: Double?, tapBuffers: Int, includeText: Bool
    ) {
        let kept = segments.filter { !$0.echo }
        let joined = kept.map(\.text).joined(separator: " ")
        self.seconds = seconds
        self.engine = engine
        self.engineFallback = engineFallback
        self.tapStatus = tapStatus
        chars = joined.count
        words = joined.split(whereSeparator: \.isWhitespace).count
        self.segments = kept.count
        self.tapZeroRatio = tapZeroRatio
        self.tapBuffers = tapBuffers
        note = words == 0
            ? "The mix is empty: nothing was transcribed. Nothing played or was said, or Microphone / System Audio Recording is not granted to Legato."
            : nil
        text = includeText ? joined : nil
    }

    /// Whether the transcript holds any word: what the self-test's exit code is about.
    public var heardSomething: Bool { words > 0 }
}
