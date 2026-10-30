import Foundation
import LegatoComposerDoc

public enum DocPresenter {
    public static func present(_ snapshot: DocumentSnapshot) -> String {
        snapshot.lines.map { line in
            let words = line.words.map { word in
                if let c = word.confidence, c < 0.9 { return "⟨\(word.text)|\(String(format: "%.2f", c))⟩" }
                return word.text
            }.joined(separator: " ")
            return "\(line.id) v\(line.version) [\(line.kind.rawValue)] \(words)"
        }.joined(separator: "\n")
    }
    public static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: #"⟨([^⟩|]*)\|[0-9.]+⟩"#, with: "$1", options: .regularExpression)
    }
}
