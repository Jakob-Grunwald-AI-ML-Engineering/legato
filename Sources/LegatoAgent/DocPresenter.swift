import Foundation

public enum DocPresenter {
    public static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: #"⟨([^⟩|]*)\|[0-9.]+⟩"#, with: "$1", options: .regularExpression)
    }
}
