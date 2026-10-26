import UIKit

/// Key captions that depend on the field and the system language (English and German).
enum KeyLabels {
    static var systemIsGerman: Bool { Locale.preferredLanguages.first?.hasPrefix("de") ?? false }

    static func returnLabel(_ type: UIReturnKeyType, german: Bool = systemIsGerman) -> String {
        if german {
            switch type {
            case .go: return "Öffnen"
            case .google, .search, .yahoo: return "Suchen"
            case .join: return "Beitreten"
            case .next, .continue: return "Weiter"
            case .route: return "Route"
            case .send: return "Senden"
            case .done: return "Fertig"
            case .emergencyCall: return "Notruf"
            default: return "Return"
            }
        }
        switch type {
        case .go: return "go"
        case .google, .search, .yahoo: return "search"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .send: return "send"
        case .done: return "done"
        case .emergencyCall: return "emergency"
        case .continue: return "continue"
        default: return "return"
        }
    }

    /// The SF Symbol the return key shows for a caption (the full keyboard and the strip share it); nil for a
    /// word, which is drawn as text.
    static func returnSymbol(for label: String) -> (name: String, weight: UIImage.SymbolWeight)? {
        switch label {
        case "return", "Return": ("return", .regular)
        case "send", "Senden": ("arrow.up", .medium)
        default: nil
        }
    }

    static func spaceLabel(german: Bool = systemIsGerman) -> String { german ? "Leerzeichen" : "space" }
}
