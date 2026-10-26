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
                // Under the grid: popups and the alternates strip are drawn over the top bar, and the grid
                // only takes touches from the first row down (`KeyGridView.point(inside:with:)`).
                suggestionBar(g)
                place(g.pillFrame) { MicKey(controller: controller) }
                KeyGrid(typing: typing, layout: layout, presentation: typing.presentation, appearance: controller.appearance)
                if controller.showsGlobe, let frame = frames["globe"] {
                    place(frame) { GlobeKey(target: controller.inputModeTarget, typing: typing) }
                }
            }
        }
        .environment(\.colorScheme, scheme)
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
        let status: String? = controller.hint ?? (controller.isCapturing && slots.isEmpty ? "Listening…" : nil)
        return Group {
            if let status {
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
