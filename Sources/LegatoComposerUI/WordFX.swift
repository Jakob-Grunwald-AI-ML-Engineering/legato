import SwiftUI

public struct ComposerWordAttribute: TextAttribute { var id: String }
/// Keeps the glyph layout native; the same measured runs drive hit testing and highlights.
public struct WordFX: TextRenderer, Animatable {
    public var progress: Double
    public var pending: Bool
    var selected: Set<String> = []
    var edit = WordEditPresentation(old: [], new: [])
    var reduceMotion = false
    var measure: (@Sendable ([String: [CGRect]]) -> Void)?
    public var animatableData: Double { get { progress } set { progress = newValue } }
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
            if !reduceMotion, local < 1, animatedRuns < 64 {
                animatedRuns += 1
                copy.addFilter(.blur(radius: (1 - local) * 4))
                copy.opacity = 0.3 + local * 0.7
                copy.addFilter(.shadow(color: .purple.opacity((1 - local) * 0.6), radius: 5))
                copy.translateBy(x: 0, y: (1 - local) * 2)
            } else if !reduceMotion, progress < 1, animatedRuns < 64, id.map(edit.deletionBoundary.contains) == true {
                animatedRuns += 1
                // A deletion has no new glyphs: mark only its surviving boundary.
                copy.addFilter(.shadow(color: .purple.opacity(sin(progress * .pi) * 0.45), radius: 4))
            }
            copy.draw(run)
        } }
        measure?(bounds)
    }
}
