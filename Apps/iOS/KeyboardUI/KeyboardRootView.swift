import LegatoKeyboardCore
import LegatoComposerUI
import SwiftUI
import UIKit

/// A composer above one native keyboard tool row. Low keeps only the grabber and tool row.
struct KeyboardRootView: View {
    let controller: KeyboardController
    @Environment(\.colorScheme) private var systemScheme
    private let modes = [("message", "message"), ("email", "envelope"), ("prompt", "sparkles"), ("note", "note.text")]

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            if controller.composerSize != .low {
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
    }

    private var toolRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(modes, id: \.0) { mode, icon in
                    Button { controller.composerIntent("mode", text: mode) } label: {
                        Label(mode.capitalized, systemImage: icon)
                    }
                }
            } label: {
                Image(systemName: modes.first(where: { $0.0 == controller.composer.mode })?.1 ?? "message")
                    .font(.system(size: 18)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } primaryAction: {
                let index = modes.firstIndex(where: { $0.0 == controller.composer.mode }) ?? 0
                controller.composerIntent("mode", text: modes[(index + 1) % modes.count].0)
            }
            .accessibilityLabel(controller.composer.mode.capitalized)
            .accessibilityHint("Tap to cycle modes. Hold to choose a writing mode")
            key("Undo", symbol: "arrow.uturn.backward", enabled: controller.canUndo, action: controller.undo)
            key("Redo", symbol: "arrow.uturn.forward", enabled: controller.canRedo, action: controller.redo)
            Button { controller.insertComposer() } label: {
                Text("Insert").font(.system(size: 14)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(controller.composer.snapshot.lines.isEmpty ? 0.35 : 1)
            }.disabled(controller.composer.snapshot.lines.isEmpty)
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
            .accessibilityHint("Swipe up or down to change size. Tap to cycle Low, Medium, and Full")
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
