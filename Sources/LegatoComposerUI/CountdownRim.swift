import SwiftUI

/// A rim that fills toward a deadline (host `systemUptime`): the automatic-send countdown of the instruction Send
/// button, the dictation pill and the keyboard's word row. Draws nothing without a countdown.
public struct CountdownRim<S: Shape>: View {
    public var shape: S
    public var start: Double?
    public var deadline: Double?
    public var lineWidth: CGFloat
    /// True for a circle, whose trim starts at 3 o'clock: it is turned to start at 12.
    public var startsAtTop: Bool

    public init(shape: S, start: Double?, deadline: Double?, lineWidth: CGFloat = 2.5, startsAtTop: Bool = false) {
        self.shape = shape; self.start = start; self.deadline = deadline; self.lineWidth = lineWidth; self.startsAtTop = startsAtTop
    }

    /// 0...1 toward the deadline; nil without a countdown.
    public static func progress(now: Double, start: Double?, deadline: Double?) -> Double? {
        guard let start, let deadline else { return nil }
        return min(1, max(0, (now - start) / max(0.001, deadline - start)))
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: deadline == nil)) { _ in
            if let progress = Self.progress(now: ProcessInfo.processInfo.systemUptime, start: start, deadline: deadline) {
                shape.trim(from: 0, to: progress).rotation(.degrees(startsAtTop ? -90 : 0))
                    .stroke(AngularGradient(colors: [.purple, .blue, .pink, .purple], center: .center),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .shadow(color: .purple.opacity(0.6), radius: 3)
                    .allowsHitTesting(false)
            }
        }
    }
}
