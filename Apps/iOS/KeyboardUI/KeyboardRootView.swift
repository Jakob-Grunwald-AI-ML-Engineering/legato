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
                if showsVersionBar {
                    place(g.suggestionFrame) { VersionBar(controller: controller) }
                }
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

    /// The status line over the slots: a hint, else the dictation status while the slots are empty.
    private var status: String? {
        controller.hint ?? (controller.suggestions.isEmpty ? controller.dictationStatus : nil)
    }

    /// After a dictation landed (and nothing else claims the bar): the version keys take the slots' place.
    private var showsVersionBar: Bool {
        controller.versions != nil && status == nil && controller.suggestions.isEmpty
    }

    /// Three slots with thin dividers. A hint or the dictation status takes the bar's place.
    private func suggestionBar(_ g: KeyGeometry) -> some View {
        let frame = g.suggestionFrame
        let slots = controller.suggestions
        return Group {
            if showsVersionBar {
                Color.clear
            } else if let status {
                Text(status)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(uiColor: KeyColors.suggestion))
                    .lineLimit(2)
                    .truncationMode(.head)
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

/// The version keys of the last dictation, in the suggestion slots: the previous version, Refine (a
/// stronger rewrite by the app), the next version. Styled like the suggestion slots.
struct VersionBar: View {
    let controller: KeyboardController

    var body: some View {
        let versions = controller.versions
        HStack(spacing: 0) {
            key(enabled: versions?.hasPrevious == true, id: "keyboard.version.previous", label: "Previous version") {
                controller.showPreviousVersion()
            } content: {
                Image(systemName: "chevron.left")
            }
            divider
            key(enabled: !controller.isRefining, id: "keyboard.version.refine", label: "Refine") {
                controller.refine()
            } content: {
                if controller.isRefining {
                    ProgressView()
                } else {
                    HStack(spacing: 4) {
                        Text("Refine")
                        if let versions, versions.texts.count > 1 {
                            Text("\(versions.current + 1)/\(versions.texts.count)").font(.system(size: 12)).monospacedDigit()
                        }
                    }
                }
            }
            divider
            key(enabled: versions?.hasNext == true, id: "keyboard.version.next", label: "Next version") {
                controller.showNextVersion()
            } content: {
                Image(systemName: "chevron.right")
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color(uiColor: KeyColors.divider)).frame(width: 0.67, height: 24)
    }

    private func key<Content: View>(
        enabled: Bool, id: String, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 17))
                .foregroundStyle(Color(uiColor: KeyColors.suggestion).opacity(enabled ? 1 : 0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
