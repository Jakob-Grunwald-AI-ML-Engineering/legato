import UIKit

/// The text field the keyboard types into. The keyboard extension backs it with `textDocumentProxy`
/// (`ProxyDocument`); the DEBUG harness in the app backs it with a `UITextView`.
@MainActor
protocol TextDocument: AnyObject {
    /// Stable for one field (`documentIdentifier`); a run's text goes only to the field it is bound to.
    /// Nil while no field is bound (the keyboard is appearing, or the host's field is gone): nothing is
    /// then applied.
    var documentID: String? { get }
    /// The text before the insertion point (`documentContextBeforeInput`); empty when there is none.
    var contextBefore: String { get }
    /// The text after the insertion point (`documentContextAfterInput`); empty when there is none.
    var contextAfter: String { get }
    /// The selected text (`selectedText`), nil when nothing is selected.
    var selectedText: String? { get }
    /// Whether the field hides what is typed (a password): nothing of it is suggested or learned.
    var isSecureTextEntry: Bool { get }
    var returnKeyType: UIReturnKeyType { get }
    var keyboardType: UIKeyboardType { get }
    var autocapitalizationType: UITextAutocapitalizationType { get }
    var enablesReturnKeyAutomatically: Bool { get }
    var keyboardAppearance: UIKeyboardAppearance { get }
    /// Whether the field holds any text (not only before the insertion point).
    var hasText: Bool { get }
    func insert(_ text: String)
    func deleteBackward()
    /// Moves the insertion point by `offset` characters (negative: back), as `adjustTextPosition(byCharacterOffset:)`.
    func adjustTextPosition(byCharacterOffset offset: Int)
}
