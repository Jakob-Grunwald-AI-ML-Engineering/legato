import LegatoKeyboardCore
import SwiftUI
import UIKit

/// The keyboard: a top bar (three suggestion slots, the mic pill) over the key grid, which is one touch
/// surface; the globe key is a view on top of its place in the layout. Geometry: `KeyboardMetrics.swift`.
struct KeyboardRootView: View {
    let controller: KeyboardController
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let typing = controller.typing!
        let layout = typing.layout
        GeometryReader { geometry in
            let g = KeyGeometry(size: geometry.size)
            let frames = Dictionary(layout.frames(in: geometry.size).map { ($0.id, $0.cgRect) }, uniquingKeysWith: { a, _ in a })
            ZStack(alignment: .topLeading) {
                if controller.mode == .strip {
                    strip(typing: typing, size: geometry.size)
                } else {
                    // Under the grid: popups and the alternates strip are drawn over the top bar, and the grid
                    // only takes touches from the first row down (`KeyGridView.point(inside:with:)`).
                    suggestionBar(g)
                    if controller.expansion.control == .collapse {
                        // The top bar above the first row takes a swipe down; the pill and the chevron stay on top.
                        place(CGRect(x: 0, y: 0, width: geometry.size.width, height: g.firstRowTop)) {
                            Color.clear.contentShape(Rectangle()).gesture(swipe)
                        }
                    }
                    place(g.pillFrame) { MicKey(controller: controller) }
                    KeyGrid(typing: typing, layout: layout, presentation: typing.presentation, appearance: controller.appearance)
                    if controller.showsGlobe, let frame = frames["globe"] {
                        place(frame) { GlobeKey(target: controller.inputModeTarget, typing: typing) }
                    }
                    if controller.expansion.control == .collapse {
                        // In the top bar's first suggestion slot (empty for now), above the first row.
                        let bar = g.suggestionFrame
                        place(CGRect(x: g.marginX, y: bar.minY, width: 44, height: bar.height)) {
                            ExpansionKey(controller: controller, symbol: "chevron.down")
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controller.mode)
        }
        .environment(\.colorScheme, scheme)
    }

    /// The compact layout: the chevron that opens the full keyboard, the globe key (when iOS asks for it),
    /// the dictation status and the mic key at the full keyboard's pill size, in one row as high as the
    /// keyboard view.
    private func strip(typing: TypingModel, size: CGSize) -> some View {
        // At the full keyboard's height: the strip's own height would scale the pill down (`vScale`).
        let fullHeight = KeyGeometry.height(landscape: KeyGeometry.isLandscape(width: size.width))
        let pill = KeyGeometry(size: CGSize(width: size.width, height: fullHeight)).pillSize
        let controlHeight = max(min(size.height - 6, pill.height), 0)
        return HStack(spacing: 8) {
            ExpansionKey(controller: controller, symbol: "chevron.up")
                .frame(width: 44, height: controlHeight)
            if controller.showsGlobe {
                GlobeKey(target: controller.inputModeTarget, typing: typing)
                    .frame(width: 44, height: controlHeight)
            }
            stripStatus
            // Touchable over the strip's full height and to the right edge, beyond the drawn pill.
            let slop = CGSize(width: 8, height: (size.height - controlHeight) / 2)
            MicKey(controller: controller, hitSlop: slop)
                .frame(width: pill.width + 2 * slop.width, height: size.height)
                .padding(.leading, -slop.width)
                .padding(.trailing, -slop.width)
        }
        .padding(.horizontal, 8)
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .simultaneousGesture(swipe)
    }

    /// A vertical swipe that expands the strip or collapses the full keyboard (`KeyboardController.swiped`).
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12).onEnded { value in
            controller.swiped(dx: value.translation.width, dy: value.translation.height)
        }
    }

    private var stripStatus: some View {
        let text = controller.statusText ?? "Legato"
        #if DEBUG
        let label = "\(text) [\(Int(controller.stripHeight)) pt]"
        #else
        let label = text
        #endif
        return Text(label)
            .font(.system(size: 15))
            .foregroundStyle(Color(uiColor: KeyColors.suggestion))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityIdentifier("keyboard.hint")
            #if DEBUG
            .onLongPressGesture { controller.cycleStripHeight() }
            #endif
    }

    private var scheme: ColorScheme {
        switch controller.appearance {
        case .dark: .dark
        case .light: .light
        default: systemScheme
        }
    }

    private func place<Content: View>(_ frame: CGRect, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    /// Three slots with thin dividers. A hint or the dictation status takes the bar's place.
    private func suggestionBar(_ g: KeyGeometry) -> some View {
        let frame = g.suggestionFrame
        let slots = controller.suggestions
        return Group {
            if let status = controller.statusText {
                Text(status)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("keyboard.hint")
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        Text(index < slots.count ? slots[index] : "")
                            .font(.system(size: 17))
                            .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .trailing) {
                                if index < 2 {
                                    Rectangle().fill(Color(uiColor: KeyColors.divider)).frame(width: 0.67, height: 24)
                                }
                            }
                    }
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
    }
}
