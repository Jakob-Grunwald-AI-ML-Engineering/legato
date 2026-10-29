import LegatoKeyboardCore
import SwiftUI
import UIKit

/// The keyboard: the word row and the tool key row over the key grid, which is one touch
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
            let screenWidth = KeyGeometry.screenWidth(in: controller.inputModeTarget?.view.window)
            let g = KeyGeometry(size: geometry.size, landscapeScreenWidth: screenWidth)
            let frames = Dictionary(layout.frames(in: geometry.size, landscapeScreenWidth: screenWidth).map { ($0.id, $0.cgRect) }, uniquingKeysWith: { a, _ in a })
            ZStack(alignment: .topLeading) {
                if controller.mode == .strip {
                    strip(typing: typing, size: geometry.size)
                } else {
                    // Under the grid: popups and the alternates strip are drawn over the top area, and the grid
                    // only takes touches from the first row down (`KeyGridView.point(inside:with:)`, at
                    // `firstRowTop - gap`, below the word row, the hotkeys and the pill).
                    if controller.expansion.control == .collapse {
                        // The area above the first row takes a swipe down, as do the controls on top of it.
                        place(CGRect(x: 0, y: 0, width: geometry.size.width, height: g.firstRowTop)) {
                            Color.clear.contentShape(Rectangle()).gesture(swipe)
                        }
                    }
                    let buttons = controller.expansion.control == .collapse ? 4 : 3
                    let wordFrame = g.wordRowFrame
                    place(wordFrame) {
                        WordRowView(
                            controller: controller, slots: WordRowLayout.visibleSlots(width: Double(wordFrame.width)), swipe: swipe)
                    }
                    place(g.hotkeyFrame(buttons: buttons)) { HotkeyBar(controller: controller, buttonWidth: g.toolWidth(buttons: buttons), swipe: swipe) }
                    place(g.micFrame(buttons: buttons)) { MicKey(controller: controller).simultaneousGesture(swipe) }
                    if typing.showsEmojiPanel {
                        place(CGRect(x: 0, y: g.firstRowTop, width: geometry.size.width, height: max(geometry.size.height - g.firstRowTop, 0))) {
                            EmojiPickerView(typing: typing, controller: controller)
                        }
                    } else {
                        KeyGrid(typing: typing, layout: layout, presentation: typing.presentation, appearance: controller.appearance, emojiSystemSwitcher: controller.emojiSystemSwitcher)
                        if controller.showsGlobe, let frame = frames["globe"] {
                            place(frame) { GlobeKey(target: controller.inputModeTarget, typing: typing) }
                        }
                        if controller.emojiSystemSwitcher, let frame = frames["emoji"] {
                            place(frame) { GlobeKey(target: controller.inputModeTarget, typing: typing, emoji: true) }
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controller.mode)
        }
        .environment(\.colorScheme, scheme)
    }

    /// The compact layout: the word row above one row as high as `stripHeight`: the chevron that opens the full
    /// keyboard, the globe key (when iOS asks for it), the hotkeys (↶ ↷ and an icon-only Refine), delete, return and the mic key at the full
    /// keyboard's native key height. `StripRow` decides the slots and widths for the keyboard width and the
    /// touch areas that tile the row. Status and hints show in the word row.
    private func strip(typing: TypingModel, size: CGSize) -> some View {
        // The word row goes above the strip's row (the height requested is the row plus the word row); the
        // debug heights that leave nothing to touch have none.
        let landscape = KeyGeometry.isLandscape(width: size.width)
        let keyRowHeight = StripHeight.keyRowHeight(row: controller.stripHeight, landscape: landscape)
        let wordRowHeight = CGFloat(StripHeight.requested(row: controller.stripHeight, landscape: landscape) - keyRowHeight)
        let rowHeight = max(size.height - wordRowHeight, 0)
        // At the full keyboard's height: the strip's own height would scale the pill down (`vScale`).
        let fullHeight = KeyGeometry.height(landscape: landscape)
        let pill = KeyGeometry(size: CGSize(width: size.width, height: fullHeight)).pillSize
        let controlHeight = max(min(rowHeight - (landscape ? 10 : 11), pill.height), 0)
        let returnStyle: StripReturnStyle = KeyLabels.returnSymbol(for: typing.presentation.returnLabel) == nil ? .text : .glyph
        let row = StripRow.make(width: size.width, showsGlobe: controller.showsGlobe, returnStyle: returnStyle)
        let bottom = min(landscape ? 4 : 3, max(rowHeight - controlHeight, 0))
        let top = max(rowHeight - controlHeight - bottom, 0)
        return VStack(spacing: 0) {
            if wordRowHeight > 0 {
                stripWordRow(width: size.width)
                    .frame(width: size.width, height: wordRowHeight)
            }
            stripRow(typing: typing, row: row, size: CGSize(width: size.width, height: rowHeight), controlHeight: controlHeight, top: top, bottom: bottom)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private func stripWordRow(width: CGFloat) -> some View {
        let slots = WordRowLayout.visibleSlots(width: Double(width))
        return WordRowView(controller: controller, slots: slots, swipe: swipe)
            // Not clear: the keyboard gets no touches on fully clear pixels.
            .background(Color.black.opacity(0.001).gesture(swipe))
            #if DEBUG
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in controller.cycleStripHeight() })
            #endif
    }

    private func stripRow(
        typing: TypingModel, row: StripRow, size: CGSize, controlHeight: CGFloat, top: CGFloat, bottom: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(row.cells, id: \.slot) { cell in
                // The key is drawn inside its touch area (`StripCell` insets, and the strip's full height).
                let insets = EdgeInsets(top: top, leading: cell.leadingInset, bottom: bottom, trailing: cell.trailingInset)
                Group {
                    switch cell.slot {
                    case .expand:
                        ExpansionKey(controller: controller, symbol: "chevron.up", insets: insets)
                            .simultaneousGesture(swipe)
                    case .globe:
                        // A UIKit button: the drawn size is its touch area.
                        GlobeKey(target: controller.inputModeTarget, typing: typing)
                            .frame(width: cell.width, height: controlHeight)
                            .padding(.top, top)
                            .padding(.bottom, bottom)
                            .padding(.leading, cell.leadingInset)
                            .padding(.trailing, cell.trailingInset)
                            .simultaneousGesture(swipe)
                    case .hotkeys:
                        HotkeyButtons(controller: controller, iconOnlyRefine: true, showsRedo: row.showsRedo, swipe: swipe)
                            .padding(.top, top)
                            .padding(.bottom, bottom)
                            .padding(.leading, cell.leadingInset)
                            .padding(.trailing, cell.trailingInset)
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
}
