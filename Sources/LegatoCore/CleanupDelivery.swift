import Foundation

/// How the cleanup agent cleans a run that streams into a text field (#80).
public enum CleanupDelivery: String, Sendable, Equatable, CaseIterable, Codable {
    /// Once, at stop: the whole text is rewritten through the cleanup session. It reads as a full rewrite, but lands
    /// as minimal patches; when the field no longer shows the run's text, the cleaned text goes to the clipboard.
    case replace
    /// While speaking: each finished sentence is rewritten as it ends and lands as minimal patches; the rest at stop.
    case live

    /// A stored or sent value, older builds' included: the removed Hold and Clipboard modes (#80) read as Live;
    /// nil for anything else.
    public init?(stored raw: String) {
        switch raw {
        case "hold", "clipboard": self = .live
        default: self.init(rawValue: raw)
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = CleanupDelivery(stored: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown delivery \(raw)"))
        }
        self = value
    }
}
