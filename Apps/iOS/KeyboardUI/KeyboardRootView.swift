import LegatoKeyboardCore
import SwiftUI
import UIKit

/// The keyboard: a top bar (three suggestion slots, the mic pill) over the key grid, which is one touch
/// surface; the globe key is a view on top of its place in the layout. Geometry: `KeyboardMetrics.swift`.
struct KeyboardRootView: View {
    let controller: KeyboardController
    @Environment(\.colorScheme) private var systemScheme
    /// Whether the current drag already toggled (`swipe`); resets when the drag ends or is cancelled.
    @GestureState private var swipeFired = false

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
                        // The top bar above the first row takes a swipe down, as do the pill and the chevron on top of it.
                        place(CGRect(x: 0, y: 0, width: geometry.size.width, height: g.firstRowTop)) {
                            Color.clear.contentShape(Rectangle()).gesture(swipe)
                        }
                    }
                    place(g.pillFrame) { MicKey(controller: controller).simultaneousGesture(swipe) }
                    KeyGrid(typing: typing, layout: layout, presentation: typing.presentation, appearance: controller.appearance)
                    if controller.showsGlobe, let frame = frames["globe"] {
                        place(frame) { GlobeKey(target: controller.inputModeTarget, typing: typing) }
                    }
                    if controller.expansion.control == .collapse {
                        // In the top bar's first suggestion slot (empty for now), above the first row.
                        let bar = g.suggestionFrame
                        place(CGRect(x: g.marginX, y: bar.minY, width: 44, height: bar.height)) {
                            ExpansionKey(controller: controller, symbol: "chevron.down").simultaneousGesture(swipe)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controller.mode)
        }
        .environment(\.colorScheme, scheme)
    }

    /// The compact layout, one row as high as the keyboard view: the chevron that opens the full keyboard,
    /// the globe key (when iOS asks for it), the dictation status, delete, return and the mic key at the full
    /// keyboard's pill size. `StripRow` decides the slots and widths for the keyboard width and the
    /// touch areas that tile the row.
    private func strip(typing: TypingModel, size: CGSize) -> some View {
        // At the full keyboard's height: the strip's own height would scale the pill down (`vScale`).
        let fullHeight = KeyGeometry.height(landscape: KeyGeometry.isLandscape(width: size.width))
        let pill = KeyGeometry(size: CGSize(width: size.width, height: fullHeight)).pillSize
        let controlHeight = max(min(size.height - 6, pill.height), 0)
        let returnStyle: StripReturnStyle = KeyLabels.returnSymbol(for: typing.presentation.returnLabel) == nil ? .text : .glyph
        let row = StripRow.make(width: size.width, showsGlobe: controller.showsGlobe, returnStyle: returnStyle)
        let vertical = max((size.height - controlHeight) / 2, 0)
        return HStack(spacing: 0) {
            ForEach(row.cells, id: \.slot) { cell in
                // The key is drawn inside its touch area (`StripCell` insets, and the strip's full height).
                let insets = EdgeInsets(top: vertical, leading: cell.leadingInset, bottom: vertical, trailing: cell.trailingInset)
                Group {
                    switch cell.slot {
                    case .expand:
                        ExpansionKey(controller: controller, symbol: "chevron.up", insets: insets)
                            .simultaneousGesture(swipe)
                    case .globe:
                        // A UIKit button: the drawn size is its touch area.
                        GlobeKey(target: controller.inputModeTarget, typing: typing)
                            .frame(width: cell.width, height: controlHeight)
                            .padding(.leading, cell.leadingInset)
                            .padding(.trailing, cell.trailingInset)
                            .simultaneousGesture(swipe)
                    case .status:
                        stripStatus(visible: row.statusTextVisible, leading: cell.leadingInset)
                            .simultaneousGesture(swipe)
                    case .delete:
                        StripDeleteKey(typing: typing, insets: insets)
                            .simultaneousGesture(swipe)
                    case .returnKey:
                        StripReturnKey(typing: typing, insets: insets)
                            .simultaneousGesture(swipe)
                    case .mic:
                        MicKey(controller: controller, hitInsets: insets)
                            .simultaneousGesture(swipe)
                    }
                }
                .frame(width: cell.hitWidth, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        // Each control takes the swipe itself (a gesture on the row loses to the controls' own); the gaps
        // and margins take it here. Not `Color.clear`: the keyboard gets no touches on fully clear pixels.
        .background(Color.black.opacity(0.001).gesture(swipe))
    }

    /// A vertical swipe that expands the strip or collapses the full keyboard (`KeyboardController.swiped`).
    /// It fires while the finger moves, once per drag: a swipe up leaves the strip's few points within a
    /// moment, and iOS then cancels the touch, so an end-of-drag handler would never run.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($swipeFired) { value, fired, _ in
                guard !fired else { return }
                let dx = value.translation.width, dy = value.translation.height
                guard controller.expansion.swipeToggles(dx: dx, dy: dy) else { return }
                fired = true
                Task { @MainActor in controller.swiped(dx: dx, dy: dy) }
            }
    }

    private func stripStatus(visible: Bool, leading: CGFloat) -> some View {
        Text(visible ? (controller.statusText ?? "Legato") : "")
            .font(.system(size: 15))
            .foregroundStyle(Color(uiColor: KeyColors.suggestion))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.leading, leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.001))
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
