import AppKit
import Observation
import SwiftUI
import LegatoMac

/// Colours, type and motion shared by the composer panel and the dictation pill.
enum NotchIslandTokens {
    static let surface = Color.black
    static let bottomRadius: CGFloat = 22
    static let detachedTopRadius: CGFloat = 20
    static let title = Font.system(size: 12, weight: .semibold)
    static let bodyPointSize: CGFloat = 14
    static let body = Font.system(size: bodyPointSize)
    static let captionPointSize: CGFloat = 11
    static let caption = Font.system(size: captionPointSize, weight: .medium)
    static let spring = Animation.spring(duration: 0.3, bounce: 0.12)
    static let closeDuration = 0.3
    // Initial Mac panel tuning, to verify at native editor sizes.
    static let departureSpring = Animation.spring(duration: 0.18, bounce: 0)
    static let departureTextLift: CGFloat = 12
    static let panelWidth: CGFloat = 520
    static let panelHorizontalInset: CGFloat = 14
    static let panelVerticalInset: CGFloat = 10
    static let panelOuterInset: CGFloat = 8
    static let panelSectionSpacing: CGFloat = 8
    static let draftLineSpacing: CGFloat = 4
    static let toolbarHeight: CGFloat = 28
    static let scrollIndicatorWidth: CGFloat = 3
    static let caretGap: CGFloat = 6
}

/// Where an island sits: attached to the hardware notch (black to the screen top, shoulders flaring into the menu bar)
/// or a detached card below the menu bar.
struct NotchIslandStyle: Equatable {
    var attached: Bool
    var safeTop: CGFloat
    var notchWidth: CGFloat

    static let detached = NotchIslandStyle(attached: false, safeTop: 0, notchWidth: NotchGeometry.fallbackNotchWidth)

    @MainActor init(screen: NSScreen) {
        self.init(attached: screen.safeAreaInsets.top > 0, safeTop: screen.safeAreaInsets.top,
                  notchWidth: NotchGeometry.notchWidth(left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea))
    }
    init(attached: Bool, safeTop: CGFloat, notchWidth: CGFloat) {
        self.attached = attached; self.safeTop = safeTop; self.notchWidth = notchWidth
    }
    var shoulder: CGFloat { attached ? NotchGeometry.shoulder : 0 }
    /// Content starts below the hardware notch.
    var topInset: CGFloat { attached ? safeTop : 0 }
    /// What the island grows out of and shrinks back into.
    func collapsed(within size: CGSize) -> CGSize {
        let box = attached ? CGSize(width: notchWidth + 2 * shoulder, height: safeTop) : CGSize(width: 160, height: 28)
        return CGSize(width: min(box.width, size.width), height: min(box.height, size.height))
    }
}

/// Drives the grow and shrink; the window keeps its target size throughout.
@MainActor @Observable
final class IslandPresentation {
    private(set) var presented = false
    func open() { guard !presented else { return }; withAnimation(NotchIslandTokens.spring) { presented = true } }
    func close() { guard presented else { return }; withAnimation(NotchIslandTokens.spring) { presented = false } }
    func jump(to value: Bool) { presented = value }
}

/// Concave shoulders into the menu bar edge and rounded bottom corners when attached; a plain rounded card otherwise.
struct NotchIslandShape: Shape {
    var shoulder: CGFloat
    var topRadius: CGFloat = NotchIslandTokens.detachedTopRadius
    var bottomRadius: CGFloat = NotchIslandTokens.bottomRadius

    func path(in rect: CGRect) -> Path {
        let bottom = min(bottomRadius, rect.height / 2, max(0, rect.width - 2 * shoulder) / 2)
        guard shoulder > 0 else {
            let top = min(topRadius, rect.height / 2)
            return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top).path(in: rect)
        }
        let s = min(shoulder, rect.height), left = rect.minX + s, right = rect.maxX - s
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + s), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - bottom))
        path.addRelativeArc(center: CGPoint(x: right - bottom, y: rect.maxY - bottom), radius: bottom, startAngle: .zero, delta: .degrees(90))
        path.addLine(to: CGPoint(x: left + bottom, y: rect.maxY))
        path.addRelativeArc(center: CGPoint(x: left + bottom, y: rect.maxY - bottom), radius: bottom, startAngle: .degrees(90), delta: .degrees(90))
        path.addLine(to: CGPoint(x: left, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

enum IslandAttachment {
    case top, bottom

    var alignment: Alignment { self == .top ? .top : .bottom }
    var anchor: UnitPoint { self == .top ? .top : .bottom }
}

/// Lets the chrome shrink toward its attachment while the content keeps its original layout.
struct NotchIsland<Content: View>: View {
    let style: NotchIslandStyle
    let presentation: IslandPresentation
    let attachment: IslandAttachment
    let departing: Bool
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in island(in: proxy.size) }
    }

    private func island(in size: CGSize) -> some View {
        let collapsed = style.collapsed(within: size)
        let openingMask = presentation.presented ? size : collapsed
        let chromeSize = departing ? collapsed : size
        let shape = NotchIslandShape(shoulder: style.shoulder)
        return ZStack(alignment: attachment.alignment) {
            shape.fill(NotchIslandTokens.surface)
                .overlay { hairline(shape) }
                .frame(width: chromeSize.width, height: chromeSize.height)
                .opacity(departing ? 0 : 1)
            content
                .padding(.top, style.topInset)
                .padding(.horizontal, style.shoulder)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .mask(alignment: attachment.alignment) {
            shape.frame(width: openingMask.width, height: openingMask.height)
        }
        .contentShape(shape)
        .opacity(presentation.presented ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func hairline(_ shape: NotchIslandShape) -> some View {
        if !style.attached { shape.stroke(.white.opacity(0.1), lineWidth: 0.5) }
    }
}
