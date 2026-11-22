import LegatoKeyboardCore
import SwiftUI

/// The keyboard's top area (#315), drawn from `TopRowLayout` in the keyboard view's coordinates: the dictation key, the
/// transcript beside it (a status or the word slots; the dictation preview has the taller `TopRowLayout.preview` frame) and, minimised, delete, return and the globe key
/// under the dictation key. Each key fills its touch area and draws its face inside it.
struct TopRowView: View {
    let controller: KeyboardController
    let layout: TopRowLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            if controller.isShowingPreview, let preview = controller.statusText {
                // A take in progress owns the area, taller than the transcript band (`TopRowLayout.preview`).
                place(layout.preview.cgRect) {
                    DictationPreviewView(controller: controller, text: preview, keySide: layout.side, bandHeight: layout.transcript.height)
                        .accessibilityIdentifier("typing.predictions")
                        .onChange(of: controller.stagedTake.runID, initial: true) { _, _ in
                            controller.notePreviewPresentation(true)
                        }
                        .onDisappear { controller.notePreviewPresentation(false) }
                }
            } else {
                place(layout.transcript.cgRect) {
                    WordRowView(controller: controller, slots: WordRowLayout.visibleSlots(width: layout.transcript.width), keySide: layout.side)
                        .accessibilityIdentifier("typing.predictions")
                }
            }
            if let exit = controller.previewExit {
                place(layout.preview.cgRect) {
                    DictationPreviewExitView(exit: exit, keySide: layout.side, bandHeight: layout.transcript.height) {
                        controller.finishPreviewExit(exit.id)
                    }
                    .id(exit.id)
                }
            }
            ForEach(layout.cells, id: \.slot) { cell in
                place(cell.hit.cgRect) { key(cell) }
            }
        }
        .onChange(of: controller.isShowingPreview) { _, _ in controller.notePreviewSelection() }
    }

    @ViewBuilder private func key(_ cell: TopRowLayout.Cell) -> some View {
        let face = cell.face, hit = cell.hit
        let insets = EdgeInsets(top: face.y - hit.y, leading: face.x - hit.x, bottom: hit.maxY - face.maxY, trailing: hit.maxX - face.maxX)
        switch cell.slot {
        case .dictation:
            MicKey(controller: controller, hitInsets: insets)
        case .globe:
            // A UIKit button: the drawn size is its touch area.
            GlobeKey(target: controller.inputModeTarget, typing: controller.typing)
                .frame(width: face.width, height: face.height)
                .padding(insets)
        case .delete:
            StripDeleteKey(typing: controller.typing, insets: insets)
        case .returnKey:
            StripReturnKey(typing: controller.typing, insets: insets)
        }
    }

    private func place<Content: View>(_ frame: CGRect, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

/// The minimised keyboard: two rows of keys on the dictation key's side, the transcript beside them (`TopRowLayout`).
struct MinimisedKeyboardView: View {
    let controller: KeyboardController

    var body: some View {
        GeometryReader { geometry in
            let typing = controller.typing!
            let returnStyle: TopRowReturnStyle = KeyLabels.returnSymbol(for: typing.presentation.returnLabel) == nil ? .text : .glyph
            let screenWidth = KeyGeometry.screenWidth(in: controller.inputModeTarget?.view.window)
            let g = KeyGeometry(size: geometry.size, landscapeScreenWidth: screenWidth)
            TopRowView(controller: controller, layout: g.topRow(mode: .minimised, side: controller.dictationKeySide,
                                                                showsGlobe: controller.showsGlobe, returnStyle: returnStyle))
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(Color.black.opacity(0.001))
        .accessibilityIdentifier("typing.minimised")
        .onAppear { controller.wordRow.contextChanged() }
        .onDisappear { controller.typing.endDelete() }
    }
}
