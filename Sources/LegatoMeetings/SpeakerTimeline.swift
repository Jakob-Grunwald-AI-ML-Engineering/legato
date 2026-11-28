import Foundation

/// Who speaks when over a whole meeting, as the after-meeting diarization found it: for each voice (a cluster, `0..<n`)
/// how much of each 20 ms frame it speaks (0...1; two voices can speak in the same frame). Built in memory for the
/// speaker cleanup and never saved.
public struct SpeakerTimeline: Sendable, Equatable {
    /// Seconds per frame.
    public static let frame: TimeInterval = 0.02

    /// `activity[cluster][frame]`, every row as long as the meeting in frames.
    public private(set) var activity: [[Float]]

    /// An empty timeline of `clusters` voices over `duration` seconds.
    public init(clusters: Int, duration: TimeInterval) {
        let frames = max(0, Int((duration / Self.frame).rounded(.up)))
        activity = [[Float]](repeating: [Float](repeating: 0, count: frames), count: max(0, clusters))
    }

    public var clusterCount: Int { activity.count }
    public var frameCount: Int { activity.first?.count ?? 0 }

    public static func frameIndex(_ time: TimeInterval) -> Int { Int((time / frame).rounded(.down)) }

    /// Sets how much `cluster` speaks in `frame` (ignored outside the timeline).
    public mutating func set(_ value: Float, cluster: Int, frame: Int) {
        guard activity.indices.contains(cluster), activity[cluster].indices.contains(frame) else { return }
        activity[cluster][frame] = value
    }

    /// How much each voice speaks from `start` to `end`: its activity summed over the frames the span touches (at least
    /// the frame of its middle).
    public func scores(from start: TimeInterval, to end: TimeInterval) -> [Float] {
        guard frameCount > 0 else { return [Float](repeating: 0, count: clusterCount) }
        var first = Self.frameIndex(min(start, end)), last = Int((max(start, end) / Self.frame).rounded(.up)) - 1
        if last < first {
            first = Self.frameIndex((start + end) / 2)
            last = first
        }
        first = max(0, first)
        last = min(frameCount - 1, last)
        return activity.map { row in
            guard first <= last else { return 0 }
            var sum: Float = 0
            for index in first...last { sum += row[index] }
            return sum
        }
    }

    /// Seconds each voice speaks in the whole meeting.
    public var speechSeconds: [TimeInterval] {
        activity.map { TimeInterval($0.reduce(0, +)) * Self.frame }
    }
}
