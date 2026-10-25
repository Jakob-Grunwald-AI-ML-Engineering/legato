import UIKit

/// The text field the keyboard types into. The keyboard extension backs it with `textDocumentProxy`
/// (`ProxyDocument`); the DEBUG harness in the app backs it with a `UITextView`.
@MainActor
protocol TextDocument: AnyObject {
    /// Stable for one field (`documentIdentifier`); a run's text goes only to the field it is bound to.
    var documentID: String { get }
    /// The text before the insertion point (`documentContextBeforeInput`); empty when there is none.
    var contextBefore: String { get }
    var returnKeyType: UIReturnKeyType { get }
    var keyboardType: UIKeyboardType { get }
    var autocapitalizationType: UITextAutocapitalizationType { get }
    var enablesReturnKeyAutomatically: Bool { get }
    var keyboardAppearance: UIKeyboardAppearance { get }
    /// Whether the field holds any text (not only before the insertion point).
    var hasText: Bool { get }
    func insert(_ text: String)
    func deleteBackward()
}
