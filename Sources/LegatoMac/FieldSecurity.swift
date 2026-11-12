import Foundation

/// One Accessibility attribute read: a value, the attribute being absent (the normal case for most elements), or any
/// other error (a timeout, a dead element from a stale tree).
public enum AXProbe: Sendable, Equatable {
    case value(String?)
    case absent
    case failed
}

/// What a dictation may assume about the focused element's security.
public enum FieldSecurity: Sendable, Equatable {
    /// Positively a password field: secure event input is on, or its role or subrole is `AXSecureTextField`.
    case password
    /// Positively not one.
    case notPassword
    /// The read failed: retry (the warm-up), and if it stays unknown dictate through the panel.
    case unknown

    public static let secureRole = "AXSecureTextField"

    /// Only a positive identification counts as a password field; a failed read is `unknown`, never `password`.
    public static func classify(secureInput: Bool, subrole: AXProbe, role: AXProbe) -> FieldSecurity {
        if secureInput { return .password }
        var failed = false
        for probe in [subrole, role] {
            switch probe {
            case .value(let value) where value == secureRole: return .password
            case .failed: failed = true
            case .value, .absent: break
            }
        }
        return failed ? .unknown : .notPassword
    }
}
