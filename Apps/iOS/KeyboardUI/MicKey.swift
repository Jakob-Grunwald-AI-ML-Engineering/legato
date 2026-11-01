import LegatoKeyboardCore
import SwiftUI

/// The dictation key. What a tap does comes from `MicKeyMode` (see `KeyboardController.micTapped`):
/// an explainer without Full Access, a `Link` that opens the app when it is not running, a request to
/// the running app otherwise. It is a tool-row key and fills the frame it is given.
struct MicKey: View {
    let controller: KeyboardController
    /// Touch area beyond the drawn key on each side; the frame given includes it.
    var hitInsets = EdgeInsets()

    var body: some View {
        switch controller.micMode {
        case .openApp:
            Link(destination: KeyboardURL.make(command: controller.openAppCommand, requestID: controller.openAppRequestID)) {
                label
            }
            .simultaneousGesture(TapGesture().onEnded { controller.micTapped() })
            .accessibilityIdentifier("key.mic")
        case .needsFullAccess, .remote:
            Button { controller.micTapped() } label: { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier("key.mic")
        }
    }

    private var capturing: Bool { controller.isCapturing }
    private var canStop: Bool { controller.micMode == .remote(.stop) || controller.routeOpen }

    /// A native key face; while capturing, filled red with a pulsing pause glyph.
    private var label: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KeyGeometry.keyRadius).fill(capturing ? Color.red : Color(uiColor: KeyColors.key))
            Image(systemName: canStop ? "pause.fill" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(capturing ? Color.white : Color.primary)
                .symbolEffect(.pulse, isActive: capturing)
        }
        .padding(hitInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(canStop ? (capturing ? "Pause dictation" : "Cancel dictation") : "Start dictation")
    }
}
