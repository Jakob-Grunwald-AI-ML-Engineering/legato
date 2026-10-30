import SwiftUI
import LegatoComposerDoc

struct AlternativesPopover: View {
    var quote: String
    var word: Word?
    var pointX: CGFloat
    var pointsDown: Bool
    var dismiss: () -> Void
    var pick: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                    .symbolEffect(.breathe, options: .repeating)
                Text(quote).font(.callout.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss correction")
            }
            if let word {
                ForEach(word.alternatives ?? [], id: \.self) { text in
                    Button(text) { pick(text) }.buttonStyle(.plain).font(.callout).foregroundStyle(.primary)
                }
            }
            Label("Speak to change this \(word == nil ? "quote" : "word")", systemImage: "waveform")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: CorrectionBubble(pointX: pointX, pointsDown: pointsDown))
        .overlay { CorrectionBubble(pointX: pointX, pointsDown: pointsDown).stroke(.purple.opacity(0.28), lineWidth: 0.7).allowsHitTesting(false) }
        .shadow(color: .purple.opacity(0.14), radius: 12, y: 3)
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}
private struct CorrectionBubble: Shape {
    var pointX: CGFloat
    var pointsDown: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 13
        let tip = min(rect.maxX - 4, max(rect.minX + 4, pointX))
        let x = min(rect.maxX - r - 9, max(rect.minX + r + 9, tip))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        if !pointsDown {
            path.addLine(to: CGPoint(x: x - 8, y: rect.minY))
            path.addLine(to: CGPoint(x: tip, y: rect.minY - 9))
            path.addLine(to: CGPoint(x: x + 8, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        if pointsDown {
            path.addLine(to: CGPoint(x: x + 8, y: rect.maxY))
            path.addLine(to: CGPoint(x: tip, y: rect.maxY + 9))
            path.addLine(to: CGPoint(x: x - 8, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
