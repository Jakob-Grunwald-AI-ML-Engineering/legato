import LegatoKeyboardCore
import LegatoComposerUI
import SwiftUI
import UIKit

/// A composer above one native keyboard tool row, with Medium and Full heights.
struct KeyboardRootView: View {
    let controller: KeyboardController
    @Environment(\.colorScheme) private var systemScheme
    @State private var showsModePicker = false
    private let modes = [("message", "message"), ("email", "envelope"), ("prompt", "sparkles"), ("note", "note.text")]

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            Group {
                ComposerView(snapshot: controller.composer.snapshot, tail: controller.composer.tail,
                             pendingLineIDs: controller.composer.pendingLineIDs, busy: controller.composer.busy,
                             onWordTap: { controller.composerIntent("tap", lineID: $0, wordID: $1) },
                             onPick: { controller.composerIntent("pick", lineID: $0, wordID: $1, text: $2) })
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                if let error = controller.composer.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(.horizontal)
                }
            }
            toolRow
        }
        // UIInputView(.keyboard) supplies the system cap/tray material. Nonzero alpha keeps blank pixels touchable.
        .background(Color.black.opacity(0.001))
        .environment(\.colorScheme, scheme)
        .animation(.easeInOut(duration: 0.2), value: controller.composerSize)
        .overlay {
            if showsModePicker {
                GeometryReader { geometry in
                    ZStack(alignment: .bottomLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle())
                            .onTapGesture { showsModePicker = false }
                            .accessibilityLabel("Dismiss writing modes")
                            .accessibilityAddTraits(.isButton)
                        KeyboardModePicker(modes: modes, selected: controller.composer.mode,
                                           keyWidth: (geometry.size.width - 12.66 - 36) / 7,
                                           maximumHeight: max(0, geometry.size.height - 66)) { mode in
                            controller.composerIntent("mode", text: mode)
                            showsModePicker = false
                        }
                        .frame(width: min(232, geometry.size.width - 12.66))
                        .padding(.leading, 6.33).padding(.bottom, 42)
                    }
                    .accessibilityAction(.escape) { showsModePicker = false }
                }
            }
        }
        .onDisappear { showsModePicker = false }
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            Button { showsModePicker.toggle() } label: {
                Image(systemName: modes.first(where: { $0.0 == controller.composer.mode })?.1 ?? "message")
                    .font(.system(size: 18)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(KeyboardModeKeyStyle(expanded: showsModePicker))
            .accessibilityLabel(controller.composer.mode.capitalized)
            .accessibilityHint("Choose a writing mode")
            key("Undo", symbol: "arrow.uturn.backward", enabled: controller.canUndo, action: controller.undo)
            key("Redo", symbol: "arrow.uturn.forward", enabled: controller.canRedo, action: controller.redo)
            Button { controller.insertComposer() } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 17))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(controller.composer.snapshot.lines.isEmpty ? 0.35 : 1)
            }.disabled(controller.composer.snapshot.lines.isEmpty).accessibilityLabel("Insert")
            key("Cancel composition", symbol: "xmark", action: { controller.composerIntent("cancel") })
            key(controller.composer.muted == true ? "Unmute transcription" : "Mute transcription",
                symbol: controller.composer.muted == true ? "mic.slash.fill" : "mic.slash",
                enabled: controller.composer.status == "listening",
                selected: controller.composer.muted == true,
                action: { controller.composerIntent("mute") })
            MicKey(controller: controller)
        }
        .font(.system(size: 17))
        .foregroundStyle(Color(uiColor: KeyColors.ink))
        .buttonStyle(KeyButtonStyle())
        .padding(.horizontal, 6.33).padding(.top, 8).padding(.bottom, 3).frame(height: 54)
        .background(Color.black.opacity(0.001)).contentShape(Rectangle())
        .highPriorityGesture(heightSwipe)
    }

    private func key(_ label: String, symbol: String, enabled: Bool = true, selected: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).opacity(enabled ? 1 : 0.35)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(KeyButtonStyle(selected: selected))
        .disabled(!enabled).accessibilityLabel(label)
    }

    private var resizeHandle: some View {
        Capsule().fill(.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, alignment: .top).padding(.top, 2)
            .frame(height: 28, alignment: .top)
            .background(Color.black.opacity(0.001)).contentShape(Rectangle())
            .gesture(heightSwipe)
            .onTapGesture { controller.setComposerSize(controller.composerSize.cycled) }
            .accessibilityElement().accessibilityLabel("Composer size")
            .accessibilityValue(controller.composerSize.rawValue.capitalized)
            .accessibilityHint("Swipe up or down to change size. Tap to switch between Medium and Full")
            .accessibilityAdjustableAction { direction in
                controller.setComposerSize(controller.composerSize.stepped(up: direction == .increment))
            }
    }

    private var heightSwipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global).onEnded { value in
            controller.setComposerSize(controller.composerSize.swiped(dx: value.translation.width, dy: value.translation.height))
        }
    }

    private var scheme: ColorScheme {
        switch controller.appearance {
        case .dark: .dark
        case .light: .light
        default: systemScheme
        }
    }
}
