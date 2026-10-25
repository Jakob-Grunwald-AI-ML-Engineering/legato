#if DEBUG
import SwiftUI
import UIKit

/// The keyboard's UI inside the app, for the simulator end-to-end run (`-LegatoKeyboardHarness YES`):
/// the real `KeyboardController`, `KeyboardRootView` and `MicKey` over a `UITextView`-backed document,
/// talking to the app's own dictation through the real App Group values and Darwin notes. The extension
/// itself can't be loaded headless, so this is the closest drive of the keyboard side. Debug builds only.
@MainActor
final class HarnessDocument: TextDocument {
    let textView = UITextView()
    let documentID = "harness-document"

    init() {
        textView.accessibilityIdentifier = "harness.document"
        textView.font = .preferredFont(forTextStyle: .title3)
        // The system keyboard never shows over the harness: the Legato keys are the only input.
        textView.inputView = UIView()
    }

    var text: String { textView.text ?? "" }

    var contextBefore: String {
        let ns = text as NSString
        return ns.substring(to: min(textView.selectedRange.location, ns.length))
    }

    var returnKeyType: UIReturnKeyType { .default }
    var keyboardType: UIKeyboardType { .default }

    func insert(_ text: String) { textView.insertText(text) }
    func deleteBackward() { textView.deleteBackward() }
}

@MainActor
final class KeyboardHarnessModel {
    static let shared = KeyboardHarnessModel()

    let document = HarnessDocument()
    let controller: KeyboardController

    private init() {
        let document = self.document
        controller = KeyboardController(document: document, link: LinkClient(), hasFullAccess: { true })
        controller.trace = { message in E2E.log("harness \(message) doc=\(E2E.quote(document.text))") }
    }

    /// `harness-mic`: a tap on the mic key.
    func run(_ command: String) {
        switch command {
        case "harness-mic": controller.micTapped()
        default: E2E.log("harness.unknown \(command)")
        }
    }
}

struct KeyboardHarness: View {
    private let model = KeyboardHarnessModel.shared

    var body: some View {
        VStack(spacing: 0) {
            HarnessTextView(textView: model.document.textView)
                .padding(8)
            KeyboardRootView(controller: model.controller)
                .frame(height: 260)
                .background(.bar)
        }
        .onAppear { model.controller.appeared() }
        .onDisappear { model.controller.disappeared() }
    }
}

private struct HarnessTextView: UIViewRepresentable {
    let textView: UITextView
    func makeUIView(context: Context) -> UITextView { textView }
    func updateUIView(_ view: UITextView, context: Context) {}
}
#endif
