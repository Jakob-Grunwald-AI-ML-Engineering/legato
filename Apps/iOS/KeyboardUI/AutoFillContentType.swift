import UIKit

/// UIKit's raw strings are framework details, not the semantic names consumed by the core policy.
/// Compare the typed constants at this boundary so system values are never guessed from their names.
enum AutoFillContentType {
    static func semanticName(for type: UITextContentType?) -> String? {
        switch type {
        case .username: "username"
        case .password: "password"
        case .newPassword: "newPassword"
        case .oneTimeCode: "oneTimeCode"
        default: nil
        }
    }
}
