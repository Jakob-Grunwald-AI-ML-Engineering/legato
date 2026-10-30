import SwiftUI

public struct ComposerWordAttribute: TextAttribute { var id: String }
/// Keeps the glyph layout native; the same measured runs drive hit testing and highlights.
public struct WordFX: TextRenderer, Animatable {
    public var progress: Double
    public var pending: Bool
    var selected: Set<String> = []
    var measure: (@Sendable ([String: [CGRect]]) -> Void)?
    public var animatableData: Double { get { progress } set { progress = newValue } }
    public init(progress: Double = 1, pending: Bool = false) { self.progress = progress; self.pending = pending }
    public func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var count = 0, bounds: [String: [CGRect]] = [:]
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
            if progress < 1 && count < 24 {
                copy.addFilter(.blur(radius: (1 - progress) * 4))
                copy.opacity = 0.3 + progress * 0.7
                copy.addFilter(.shadow(color: .purple.opacity((1 - progress) * 0.6), radius: 5))
                copy.translateBy(x: 0, y: (1 - progress) * 2)
            }
            copy.draw(run); count += 1
        } }
        measure?(bounds)
    }
}
