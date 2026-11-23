import SwiftUI

/// The listening glow moves across the preview while Magic is gathering an instruction.
public struct MagicPreviewGlow: View {
    public let origin: CGPoint?
    public init(origin: CGPoint? = nil) { self.origin = origin }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        if reduceMotion {
            Color.primary.opacity(0.08)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { context, size in
                    let origin = origin ?? CGPoint(x: size.width / 2, y: size.height / 2)
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / MagicPreviewEffects.shimmerPeriod
                    let center = CGPoint(x: origin.x * 0.4 + size.width * (0.3 + 0.16 * sin(phase)),
                                         y: size.height * (0.5 + 0.2 * cos(phase)))
                    let colors = MagicGradient.colors.map { $0.opacity(0.16) }
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .radialGradient(Gradient(colors: colors + [.clear]), center: center,
                                                       startRadius: 0, endRadius: max(1, size.width * 0.75)))
                }
            }
        }
    }
}

/// Drawing shared by the Mac panel and the iPhone keyboard preview.
public enum MagicPreviewEffects {
    public static let lift: CGFloat = 6
    public static let poofSeconds = 0.22
    public static let shimmerPeriod = 3.2

    public static func marked<Attribute: TextAttribute & Equatable>(_ text: String, role: (Int) -> Attribute?) -> Text {
        let body = Array(text)
        let roles = body.indices.map(role)
        var result = Text("")
        var start = 0
        while start < body.count {
            var end = start + 1
            while end < body.count, roles[end] == roles[start] { end += 1 }
            var piece = Text(String(body[start..<end]))
            if let role = roles[start] { piece = piece.customAttribute(role) }
            result = Text("\(result)\(piece)")
            start = end
        }
        return result
    }

    public static func drawPoof(_ run: Text.Layout.Run, progress: Double, in context: GraphicsContext) {
        guard progress < 1 else { return }
        var copy = context
        copy.translateBy(x: 0, y: -lift * CGFloat(progress))
        copy.opacity = 1 - progress
        copy.addFilter(.blur(radius: 4 * progress))
        copy.draw(run)
    }

    public static func drawShimmer(_ glyphs: [Text.Layout.RunSlice], in layout: Text.Layout, now: Date, context: GraphicsContext) {
        guard !glyphs.isEmpty else { return }
        let bounds = layout.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
        let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: shimmerPeriod) / shimmerPeriod
        var overlay = context
        overlay.opacity = 0.6
        overlay.clipToLayer { mask in for glyph in glyphs { mask.draw(glyph) } }
        let width = max(bounds.width, 1)
        overlay.fill(Path(bounds), with: .linearGradient(Gradient(colors: MagicGradient.colors),
                                                         startPoint: CGPoint(x: bounds.minX - width + 2 * width * phase, y: bounds.midY),
                                                         endPoint: CGPoint(x: bounds.minX + 2 * width * phase, y: bounds.midY)))
    }
}
