import SwiftUI

public struct ComposerWordAttribute: TextAttribute { var id: String }
/// Keeps the glyph layout native; the same measured runs drive hit testing and highlights.
public struct WordFX: TextRenderer, Animatable {
    public var progress: Double
    public var pending: Bool
    var selected: Set<String> = []
    var edit = WordEditPresentation(old: [], new: [])
    var reduceMotion = false
    var shine: DictationShinePlan?
    var shineProgress = 1.0
    var measure: (@Sendable ([String: [CGRect]]) -> Void)?
    public var animatableData: AnimatablePair<Double, Double> {
        get { .init(progress, shineProgress) }
        set { progress = newValue.first; shineProgress = newValue.second }
    }
    public init(progress: Double = 1, pending: Bool = false) { self.progress = progress; self.pending = pending }
    public func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var bounds: [String: [CGRect]] = [:]
        var animatedRuns = 0
        for line in layout { for run in line {
            let rect = run.typographicBounds.rect
            let id = run[ComposerWordAttribute.self]?.id
            if let id { bounds[id, default: []].append(rect) }
            var copy = context
            if pending || id.map(selected.contains) == true {
                let path = Path(roundedRect: rect.insetBy(dx: -1, dy: -2), cornerRadius: 4)
                copy.fill(path, with: .linearGradient(Gradient(colors: [.purple.opacity(0.2), .blue.opacity(0.13)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                if id.map(selected.contains) == true { copy.stroke(path, with: .color(.purple.opacity(0.28)), lineWidth: 0.6) }
            }
            let local = id.map { edit.progress(for: $0, overall: progress) } ?? 1
            let gleam = id.flatMap { shine?.progress(for: $0, overall: shineProgress) }
            let isShining = gleam.map { $0 > 0 && $0 < 1 } == true
            let deletion = progress < 1 && id.map(edit.deletionBoundary.contains) == true
            let effectBounds = WordEffectSurface.bounds(for: rect)
            let boundedEffect = !reduceMotion && animatedRuns < 64 && effectBounds != nil
                && (local < 1 || deletion || isShining)
            if boundedEffect, let effectBounds {
                // Clip BEFORE either filters or drawLayer: both otherwise inherit the full
                // Text canvas and can allocate an enormous paragraph-sized GPU texture.
                copy.clip(to: Path(effectBounds))
                animatedRuns += 1
                if local < 1 {
                    copy.addFilter(.blur(radius: (1 - local) * 4))
                    copy.opacity = 0.3 + local * 0.7
                    copy.addFilter(.shadow(color: .purple.opacity((1 - local) * 0.6), radius: 5))
                    copy.translateBy(x: 0, y: (1 - local) * 2)
                } else if deletion {
                    copy.addFilter(.shadow(color: .purple.opacity(sin(progress * .pi) * 0.45), radius: 4))
                }
                if isShining, let gleam {
                    // Pow's familiar diagonal white glint and source-atop blend, isolated
                    // to ONE bounded glyph run rather than a whole-content compositingGroup.
                    let width = max(12, min(40, rect.width * 0.55))
                    let center = rect.minX - width + (rect.width + width * 2) * gleam
                    let strength = sin(gleam * .pi)
                    copy.drawLayer { layer in
                        layer.draw(run)
                        var beam = layer
                        beam.blendMode = .sourceAtop
                        beam.fill(Path(rect), with: .linearGradient(Gradient(colors: [
                            .clear, .purple.opacity(strength * 0.35), .white.opacity(strength * 0.98), .clear
                        ]), startPoint: CGPoint(x: center - width / 2, y: rect.minY),
                            endPoint: CGPoint(x: center + width / 2, y: rect.maxY)))
                    }
                } else { copy.draw(run) }
            } else { copy.draw(run) }
        } }
        measure?(bounds)
    }
}

/// Effects are optional presentation: an oversized run always draws normally rather than
/// requesting a paragraph-sized GPU texture. At 3x this caps a filter surface at 1.125 MiB.
enum WordEffectSurface {
    static let halo: CGFloat = 8
    static let maximumSide: CGFloat = 512
    static let maximumArea: CGFloat = 32_768
    static func bounds(for run: CGRect) -> CGRect? {
        guard !run.isNull, !run.isInfinite, run.width > 0, run.height > 0 else { return nil }
        let bounds = run.insetBy(dx: -halo, dy: -halo)
        guard bounds.width <= maximumSide, bounds.height <= maximumSide,
              bounds.width * bounds.height <= maximumArea else { return nil }
        return bounds
    }
}
