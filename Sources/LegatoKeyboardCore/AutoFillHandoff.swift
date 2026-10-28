import Foundation

/// Metadata-only policy; never reads or retains a field's text. Keep one instance for the extension
/// process, so returning to Legato (including a recreated controller) never immediately sends it away.
public struct AutoFillHandoff {
    public static let preferenceKey = "keyboardAutomaticAutoFill"
    public static let defaultEnabled = false
    private struct Field: Hashable {
        let documentID: String
        let contentType: String
    }
    private var attempted: Set<Field> = []

    public init() {}

    public static func offersAction(contentType: String?) -> Bool {
        switch contentType {
        case "username", "password", "newPassword", "oneTimeCode": true
        default: false
        }
    }

    /// At most one handoff for each identified credential field and trait in this process. Off, hidden,
    /// unbound and unavailable states do not consume the attempt. The caller switches immediately on true.
    public mutating func shouldSwitch(
        documentID: String?, contentType: String?, enabled: Bool = Self.defaultEnabled,
        visible: Bool, targetAvailable: Bool
    ) -> Bool {
        guard enabled, visible, targetAvailable, let documentID, !documentID.isEmpty,
              let contentType, Self.offersAction(contentType: contentType) else { return false }
        return attempted.insert(Field(documentID: documentID, contentType: contentType)).inserted
    }
}
