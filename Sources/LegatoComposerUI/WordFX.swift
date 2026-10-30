import SwiftUI

public struct ComposerWordAttribute: TextAttribute {}
/// A single animation clock per line; at most twelve runs receive blur at once.
public struct WordFX: TextRenderer, Animatable {
    public var progress: Double
    public var pending: Bool
    public var animatableData: Double { get { progress } set { progress = newValue } }
    public init(progress: Double = 1, pending: Bool = false) { self.progress = progress; self.pending = pending }
    public func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var count = 0
        for line in layout { for run in line {
            var copy = context
            if pending { copy.fill(Path(roundedRect: run.typographicBounds.rect, cornerRadius: 3), with: .color(.accentColor.opacity(0.14))) }
            if progress < 1 && count < 12 { copy.addFilter(.blur(radius: (1 - progress) * 3)); copy.opacity = 0.45 + progress * 0.55 }
            copy.draw(run); count += 1
        } }
    }
}
