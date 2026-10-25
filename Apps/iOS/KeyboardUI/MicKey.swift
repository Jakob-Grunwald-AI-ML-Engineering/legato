import LegatoKeyboardCore
import SwiftUI

/// The dictation key. What a tap does comes from `MicKeyMode` (see `KeyboardController.micTapped`):
/// an explainer without Full Access, a `Link` that opens the app when it is not running, a request to
/// the running app otherwise.
struct MicKey: View {
    let controller: KeyboardController

    var body: some View {
        switch controller.micMode {
        case .openApp:
            Link(destination: KeyboardURL.make(command: .start, requestID: controller.openAppRequestID)) {
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

    private var fill: Color { capturing ? .red : Color.accentColor }

    private var label: some View {
        Image(systemName: capturing ? "stop.fill" : "mic.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: KeyStyle.height)
            .background(fill, in: RoundedRectangle(cornerRadius: KeyStyle.radius))
            .contentShape(Rectangle())
    }
}
