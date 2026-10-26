import LegatoKeyboardCore
import SwiftUI

/// The dictation key. What a tap does comes from `MicKeyMode` (see `KeyboardController.micTapped`):
/// an explainer without Full Access, a `Link` that opens the app when it is not running, a request to
/// the running app otherwise. It is the pill at the right of the top bar and fills the frame it is given.
struct MicKey: View {
    let controller: KeyboardController
    /// Touch area beyond the drawn pill on each side; the frame given includes it.
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

    /// The pill of the top bar: an outlined capsule; while capturing, filled red with a pulsing stop glyph.
    private var label: some View {
        ZStack {
            Capsule().fill(capturing ? Color.red : Color.clear)
            Capsule().strokeBorder(capturing ? Color.clear : Color.primary.opacity(0.22), lineWidth: 2)
            Image(systemName: capturing ? "stop.fill" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(capturing ? Color.white : Color.primary)
                .symbolEffect(.pulse, isActive: capturing)
        }
        .padding(hitInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(hitInsets == EdgeInsets() ? AnyShape(Capsule()) : AnyShape(Rectangle()))
    }
}
