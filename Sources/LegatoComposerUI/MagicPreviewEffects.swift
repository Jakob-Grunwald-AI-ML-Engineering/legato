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

/// The ripple at the point where Magic starts. Desktop actions originate at the center of the preview.
public struct MagicPreviewRipple: View {
    public static let seconds = 0.35
    private let start: Date
    private let origin: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(start: Date, origin: CGPoint? = nil) {
        self.start = start
        self.origin = origin
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            let duration = reduceMotion ? 0.2 : Self.seconds
            let progress = min(1, max(0, timeline.date.timeIntervalSince(start) / duration))
            Canvas { context, size in
                let bounds = Path(CGRect(origin: .zero, size: size))
                if reduceMotion {
                    context.fill(bounds, with: .color(.primary.opacity(0.1 * (1 - progress))))
                } else {
                    let center = origin ?? CGPoint(x: size.width / 2, y: size.height / 2)
                    let remaining = 1 - progress
                    let reach = hypot(max(center.x, size.width - center.x),
                                      max(center.y, size.height - center.y))
                    let radius = max(1, reach * (1 - remaining * remaining))
                    let colors = MagicGradient.colors.map { $0.opacity(0.4 * remaining * remaining) }
                    context.fill(bounds, with: .radialGradient(Gradient(colors: colors + [.clear]),
                                                               center: center, startRadius: 0, endRadius: radius))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Drawing shared by the Mac panel and the iPhone keyboard preview.
public enum MagicPreviewEffects {
    public static let lift: CGFloat = 6
    public static let poofSeconds = 0.22
    public static let entranceSeconds = 0.15
    public static let shimmerPeriod = 3.2
    private static let poofBlurRadius: CGFloat = 4
    public static var verticalEffectReach: CGFloat { lift + poofBlurRadius }

    public static func marked<Attribute: TextAttribute & Equatable>(_ text: String, role: (Int) -> Attribute?) -> Text {
        let body = Array(text)
        let roles = body.indices.map(role)
        var pieces: [Text] = []
        var start = 0
        while start < body.count {
            var end = start + 1
            while end < body.count, roles[end] == roles[start] { end += 1 }
            var piece = Text(String(body[start..<end]))
            if let role = roles[start] { piece = piece.customAttribute(role) }
            pieces.append(piece)
            start = end
        }
        // A balanced tree keeps SwiftUI's layout and traversal shallow even if roles alternate across a long draft.
        func join(_ runs: ArraySlice<Text>) -> Text {
            if runs.count < 2 { return runs.first ?? Text("") }
            let middle = runs.index(runs.startIndex, offsetBy: runs.count / 2)
            return Text("\(join(runs[..<middle]))\(join(runs[middle...]))")
        }
        return join(pieces[...])
    }

    public static func drawPoof(_ run: Text.Layout.Run, progress: Double, in context: GraphicsContext) {
        guard progress < 1 else { return }
        var copy = context
        copy.translateBy(x: 0, y: -lift * CGFloat(progress))
        copy.opacity = 1 - progress
        copy.addFilter(.blur(radius: poofBlurRadius * progress))
        copy.draw(run)
    }

    public static func drawSurvivor(_ glyph: Text.Layout.RunSlice, from old: CGRect, verticalAdjustment: CGFloat = 0,
                                    progress: Double, in context: GraphicsContext) {
        let current = glyph.typographicBounds.rect
        let remainder = CGFloat((1 - progress) * (1 - progress))
        var copy = context
        copy.translateBy(x: (old.minX - current.minX) * remainder,
                         y: (old.minY - current.minY + verticalAdjustment) * remainder)
        copy.draw(glyph)
    }

    public static func drawEntrance(_ glyph: Text.Layout.RunSlice, progress: Double, in context: GraphicsContext) {
        guard progress > 0 else { return }
        var copy = context
        copy.opacity = progress
        copy.translateBy(x: 0, y: lift * CGFloat(1 - progress))
        copy.draw(glyph)
    }

    public static func drawShimmer(_ glyphs: [Text.Layout.RunSlice], in layout: Text.Layout, now: Date, context: GraphicsContext,
                                   viewport: CGRect? = nil) {
        guard !glyphs.isEmpty else { return }
        let bounds = layout.reduce(CGRect.null) { $0.union($1.typographicBounds.rect) }
        let fillBounds = viewport.map { bounds.intersection($0) } ?? bounds
        guard !fillBounds.isEmpty else { return }
        let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: shimmerPeriod) / shimmerPeriod
        var overlay = context
        overlay.opacity = 0.6
        if let viewport { overlay.clip(to: Path(viewport)) }
        overlay.clipToLayer { mask in for glyph in glyphs { mask.draw(glyph) } }
        let width = max(bounds.width, 1)
        overlay.fill(Path(fillBounds), with: .linearGradient(Gradient(colors: MagicGradient.colors),
                                                         startPoint: CGPoint(x: bounds.minX - width + 2 * width * phase, y: bounds.midY),
                                                         endPoint: CGPoint(x: bounds.minX + 2 * width * phase, y: bounds.midY)))
    }
}
