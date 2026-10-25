import UIKit

/// The host app's text field, through `textDocumentProxy`.
@MainActor
final class ProxyDocument: TextDocument {
    private let proxy: () -> any UITextDocumentProxy

    init(proxy: @escaping () -> any UITextDocumentProxy) {
        self.proxy = proxy
    }

    var documentID: String { proxy().documentIdentifier.uuidString }
    var contextBefore: String { proxy().documentContextBeforeInput ?? "" }
    var returnKeyType: UIReturnKeyType { proxy().returnKeyType ?? .default }
    var keyboardType: UIKeyboardType { proxy().keyboardType ?? .default }

    func insert(_ text: String) { proxy().insertText(text) }
    func deleteBackward() { proxy().deleteBackward() }
}
