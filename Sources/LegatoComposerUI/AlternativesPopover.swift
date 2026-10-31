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
    var sendLabel = "Apply correction"
    var accessibilityPrefix = "composer.correction"
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(headerTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                if applying { ProgressView().controlSize(.mini) }
                if showsSendButton {
                    Button { send?() } label: {
                        Image(systemName: "wand.and.stars").foregroundStyle(.purple).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).disabled(send == nil || capturedText.isEmpty || applying)
                    .accessibilityLabel(sendLabel).accessibilityIdentifier(accessibilityPrefix + ".send")
                }
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel(dismissLabel)
                    .accessibilityIdentifier(accessibilityPrefix + ".discard")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(capturedText.isEmpty ? "…" : capturedText).font(.callout).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier(accessibilityPrefix + ".speech")
                        Color.clear.frame(height: 1).id("spoken-end")
                    }
                }
                .scrollIndicators(.hidden)
                .task(id: capturedText) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo("spoken-end", anchor: .bottom)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(height: min(maximumHeight, capturedText.isEmpty ? 54 : 96))
        .background(.regularMaterial, in: CorrectionBubble(pointX: pointX, pointsDown: pointsDown))
        .overlay { CorrectionBubble(pointX: pointX, pointsDown: pointsDown).stroke(.purple.opacity(0.28), lineWidth: 0.7).allowsHitTesting(false) }
        .shadow(color: .purple.opacity(0.14), radius: 8, y: 2)
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
