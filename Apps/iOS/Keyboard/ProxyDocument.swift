import UIKit

import LegatoKeyboardCore

/// The host app's text field, through `textDocumentProxy`. The proxy is looked up on every access and may
/// be missing (the view controller is gone): reads then give the defaults and edits do nothing.
@MainActor
final class ProxyDocument: TextDocument {
    private let proxy: () -> (any UITextDocumentProxy)?

    init(proxy: @escaping () -> (any UITextDocumentProxy)?) {
        self.proxy = proxy
    }

    /// `documentIdentifier` is imported as a non-optional `UUID` but is nil while no field is bound; reading
    /// it as such traps in the bridge, so it is read by selector (`NilSafeObjC`).
    var documentID: String? {
        guard let proxy = proxy() else { return nil }
        return NilSafeObjC.uuid("documentIdentifier", of: proxy)?.uuidString
    }
    var contextBefore: String { proxy()?.documentContextBeforeInput ?? "" }
    var contextAfter: String { proxy()?.documentContextAfterInput ?? "" }
    var selectedText: String? { proxy()?.selectedText }
    var isSecureTextEntry: Bool { proxy()?.isSecureTextEntry ?? false }
    var returnKeyType: UIReturnKeyType { proxy()?.returnKeyType ?? .default }
    var keyboardType: UIKeyboardType { proxy()?.keyboardType ?? .default }
    var autocapitalizationType: UITextAutocapitalizationType { proxy()?.autocapitalizationType ?? .sentences }
    var enablesReturnKeyAutomatically: Bool { proxy()?.enablesReturnKeyAutomatically ?? false }
    var keyboardAppearance: UIKeyboardAppearance { proxy()?.keyboardAppearance ?? .default }
    var hasText: Bool { proxy()?.hasText ?? false }

    func insert(_ text: String) { proxy()?.insertText(text) }
    func deleteBackward() { proxy()?.deleteBackward() }
    func adjustTextPosition(byCharacterOffset offset: Int) { proxy()?.adjustTextPosition(byCharacterOffset: offset) }
}
