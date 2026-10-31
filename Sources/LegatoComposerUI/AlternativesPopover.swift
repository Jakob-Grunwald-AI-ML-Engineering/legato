import SwiftUI
import LegatoComposerDoc

struct AlternativesPopover: View {
    var capturedText: String
    var pointX: CGFloat
    var pointsDown: Bool
    var maximumHeight: CGFloat
    var countdownStart: Double?
    var countdownDeadline: Double?
    var dismiss: () -> Void
    var send: (() -> Void)?
    var headerTitle = "Speak a correction"
    var dismissLabel = "Cancel correction"
    var showsSendButton = true
    var applying = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(headerTitle).font(.caption).foregroundStyle(.primary.opacity(0.75))
                    Spacer(minLength: 4)
                    if applying { ProgressView().controlSize(.mini) }
                    Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                        .buttonStyle(.plain).accessibilityLabel(dismissLabel)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Text(capturedText.isEmpty ? "…" : capturedText).font(.callout).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showsSendButton { TimelineView(.animation(minimumInterval: 1.0 / 30, paused: countdownDeadline == nil)) { _ in
                        Button { send?() } label: {
                            Image(systemName: "wand.and.stars").foregroundStyle(.purple).frame(width: 28, height: 28)
                                .overlay {
                                    if let start = countdownStart, let deadline = countdownDeadline {
                                        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - start) / max(0.001, deadline - start)))
                                        RoundedRectangle(cornerRadius: 8).trim(from: 0, to: progress)
                                            .stroke(AngularGradient(colors: [.purple, .blue, .pink, .purple], center: .center), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                            .shadow(color: .purple.opacity(0.6), radius: 4)
                                    }
                                }
                        }
                        .buttonStyle(.plain).disabled(send == nil || capturedText.isEmpty).accessibilityLabel("Apply correction")
                    } }
                }
            }.padding(11)
        }
        .scrollIndicators(.hidden)
        .frame(height: min(maximumHeight, capturedText.isEmpty ? 68 : 100))
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
