/// The operations a readable field can use. A settable whole value identifies an editable field, but does not
/// promise that scoped replacements work: native web views can expose AXValue without AXSelectedText's setter.
public struct FieldWriteCapabilities: Sendable, Equatable {
    public let editsInPlace: Bool
    public let typesKeys: Bool

    public init(chromium: Bool, editable: Bool, selectedTextSettable: Bool, textOperation: Bool, scopedWriteFailed: Bool = false) {
        // Chromium advertises setters it ignores. WebKit's scoped marker operation is usable even when its
        // selected-text setter is absent; every operation still receives the queue's independent readback.
        editsInPlace = !scopedWriteFailed && !chromium && (selectedTextSettable || textOperation)
        typesKeys = !editsInPlace && editable
    }
}

/// Positive evidence that a focused Accessibility element is a typing destination, independent of whether its text
/// currently reads. A settable value on a Finder list, slider or page is not permission to send keyboard input.
public enum FieldTypingDestination {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"]

    public static func accepts(role: String?, textSettable: Bool, editableAncestorRole: String? = nil) -> Bool {
        if let role, textRoles.contains(role), textSettable || role == "AXSecureTextField" { return true }
        return editableAncestorRole.map { textRoles.contains($0) } ?? false
    }
}
