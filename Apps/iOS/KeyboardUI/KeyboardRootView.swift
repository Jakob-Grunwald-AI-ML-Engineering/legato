import LegatoKeyboardCore
import LegatoComposerUI
import SwiftUI
import UIKit

/// The keyboard: the word row and the tool key row over the key grid, which is one touch
/// surface; the globe key is a view on top of its place in the layout. Geometry: `KeyboardMetrics.swift`.
struct KeyboardRootView: View {
    let controller: KeyboardController
    @Environment(\.colorScheme) private var systemScheme
    /// Whether the current drag already toggled (`swipe`); resets when the drag ends or is cancelled.
    @GestureState private var swipeFired = false

    @State private var resizeStart: Double?
    @State private var resizePreview: Double?
    @GestureState private var resizing = false

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            ComposerView(snapshot: controller.composer.snapshot, tail: controller.composer.tail,
                         pendingLineIDs: controller.composer.pendingLineIDs, busy: controller.composer.busy,
                         onWordTap: { controller.composerIntent("tap", lineID: $0, wordID: $1) },
                         onPick: { controller.composerIntent("pick", lineID: $0, wordID: $1, text: $2) })
                .frame(maxHeight: .infinity)
            if let error = controller.composer.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            HStack(spacing: 16) {
                ModeChip(mode: controller.composer.mode) { controller.composerIntent("mode", text: $0) }
                Spacer()
                Button { controller.composerIntent("undo") } label: { Image(systemName: "arrow.uturn.backward") }
                Button("Insert") { controller.insertComposer() }.disabled(controller.composer.snapshot.lines.isEmpty)
                Button { controller.composerIntent("cancel") } label: { Image(systemName: "xmark") }
            }.buttonStyle(.borderless).padding(.horizontal, 14).frame(height: 38)
            keyboardBody.frame(height: CGFloat(StripHeight.keyRowHeight(row: controller.stripHeight, landscape: false)))
        }
        // UIInputView(.keyboard) supplies the same adaptive material as the system tray.
        // A nonzero alpha also keeps blank portions touchable in keyboard extensions.
        .background(Color.black.opacity(0.001))
        .environment(\.colorScheme, scheme)
        .overlay(alignment: .top) {
            if let resizePreview {
                GeometryReader { geometry in
                    VStack(spacing: 5) {
                        Capsule().fill(.tint).frame(width: 48, height: 3)
                        Text("\(Int(resizePreview)) pt").font(.caption.monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .offset(y: max(0, geometry.size.height - resizePreview))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
    private var screenHeight: Double {
        Double(controller.inputModeTarget?.view.window?.windowScene?.screen.bounds.height ?? 874)
    }

    private var resizeHandle: some View {
        Capsule().fill(.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 2)
            .frame(height: 28, alignment: .top)
            .background(Color.black.opacity(0.001))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($resizing) { _, active, _ in active = true }
                .onChanged { value in
                    if resizeStart == nil { resizeStart = ComposerKeyboardHeight.resolve(controller.composerHeight, screenHeight: screenHeight) }
                    // Preview only. Resizing the host on every move makes native layout lag behind the finger.
                    resizePreview = ComposerKeyboardHeight.resized(
                        start: resizeStart ?? controller.composerHeight,
                        translation: value.translation.height, screenHeight: screenHeight)
                }
                .onEnded { value in
                    let height = ComposerKeyboardHeight.resized(start: resizeStart ?? controller.composerHeight,
                        translation: value.translation.height, screenHeight: screenHeight)
                    resizeStart = nil
                    resizePreview = nil
                    controller.resizeComposer(to: height)
                })
            .onChange(of: resizing) { _, active in
                // iOS may cancel an upward drag when it leaves the extension. Never commit on cancellation.
                if !active { resizeStart = nil; resizePreview = nil }
            }
            .onTapGesture {
                // Expansion remains available when an upward drag leaves this extension's touch surface.
                let height = controller.composerHeight < 430 ? 600.0 : 260.0
                controller.resizeComposer(to: ComposerKeyboardHeight.resolve(height, screenHeight: screenHeight))
            }
            .accessibilityElement()
            .accessibilityLabel("Resize composer")
            .accessibilityValue("\(Int(controller.composerHeight)) points")
            .accessibilityHint("Drag to resize, or tap to switch between compact and expanded")
            .accessibilityAdjustableAction { direction in
                let change: Double = direction == .increment ? 60 : -60
                controller.resizeComposer(to: ComposerKeyboardHeight.resolve(controller.composerHeight + change, screenHeight: screenHeight))
            }
    }

    private var keyboardBody: some View {
        GeometryReader { geometry in
            strip(typing: controller.typing!, size: geometry.size)
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
        let wordRowHeight: CGFloat = 0
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
        return WordRowView(controller: controller, slots: slots,
                           contentOffset: WordRowHeight.textOffset(landscape: KeyGeometry.isLandscape(width: width)), swipe: swipe)
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
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(true)
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
