import LegatoKeyboardCore
import SwiftUI

/// The compact layout: the word row (live words, dictation and instruction status) above one row of keys, as
/// high as `KeyboardController.stripHeight`: chevron (open the full keyboard), the globe key (when iOS asks for
/// it), magic, mic, undo, redo, delete, return. `StripRow` decides the slots and widths for the keyboard width and the
/// touch areas that tile the row; `StripGeometry` the heights. A swipe up expands.
struct StripView: View {
    let controller: KeyboardController

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let g = StripGeometry(size: size, stripHeight: controller.stripHeight)
            let typing = controller.typing!
            let returnStyle: StripReturnStyle = KeyLabels.returnSymbol(for: typing.presentation.returnLabel) == nil ? .text : .glyph
            let row = StripRow.make(width: size.width, showsGlobe: controller.showsGlobe, returnStyle: returnStyle)
            VStack(spacing: 0) {
                if g.wordRowHeight > 0 {
                    wordRow(width: size.width, landscape: g.landscape)
                        .frame(width: size.width, height: g.wordRowHeight)
                }
                keyRow(typing: typing, row: row, geometry: g, width: size.width)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .accessibilityIdentifier("typing.strip")
        .onAppear { controller.wordRow.contextChanged() }
        .onDisappear { controller.typing.endDelete() }
    }

    private func wordRow(width: CGFloat, landscape: Bool) -> some View {
        WordRowView(controller: controller, slots: WordRowLayout.visibleSlots(width: Double(width)))
            .accessibilityIdentifier("typing.predictions")
            // Not clear: the keyboard gets no touches on fully clear pixels.
            .background(Color.black.opacity(0.001))
            .expansionSwipe(controller)
            #if DEBUG
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.8).onEnded { _ in controller.cycleStripHeight() })
            #endif
    }

    private func keyRow(typing: TypingModel, row: StripRow, geometry g: StripGeometry, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(row.cells, id: \.slot) { cell in
                // The key is drawn inside its touch area (`StripCell` insets, and the row's full height).
                let insets = EdgeInsets(top: g.top, leading: cell.leadingInset, bottom: g.bottom, trailing: cell.trailingInset)
                Group {
                    switch cell.slot {
                    case .expand:
                        ExpansionKey(controller: controller, symbol: "chevron.up", insets: insets)
                    case .globe:
                        // A UIKit button: the drawn size is its touch area.
                        GlobeKey(target: controller.inputModeTarget, typing: typing)
                            .frame(width: cell.width, height: g.controlHeight)
                            .padding(.top, g.top)
                            .padding(.bottom, g.bottom)
                            .padding(.leading, cell.leadingInset)
                            .padding(.trailing, cell.trailingInset)
                    case .magic:
                        MagicKey(controller: controller, hitInsets: insets)
                    case .mic:
                        MicKey(controller: controller, hitInsets: insets)
                    case .undo:
                        StripHistoryKey(label: "Undo", symbol: "arrow.uturn.backward", id: "keyboard.hotkey.undo",
                                        enabled: controller.canUndo, feedback: typing.feedback, insets: insets, action: controller.undo)
                    case .redo:
                        StripHistoryKey(label: "Redo", symbol: "arrow.uturn.forward", id: "keyboard.hotkey.redo",
                                        enabled: controller.canRedo, feedback: typing.feedback, insets: insets, action: controller.redo)
                    case .delete:
                        StripDeleteKey(typing: typing, insets: insets)
                    case .returnKey:
                        StripReturnKey(typing: typing, insets: insets)
                    }
                }
                // Each key takes the swipe itself, beside its tap; the gaps and margins take it below.
                .expansionSwipe(controller)
                .frame(width: cell.hitWidth, height: g.rowHeight)
            }
        }
        .frame(width: width, height: g.rowHeight, alignment: .leading)
        // Not `Color.clear`: the keyboard gets no touches on fully clear pixels.
        .background(Color.black.opacity(0.001).expansionSwipe(controller))
    }
}
