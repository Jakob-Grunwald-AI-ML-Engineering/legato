import SwiftUI
public enum ConfidenceTint {
    public static func color(_ confidence: Double?) -> Color {
        guard let confidence, confidence < 0.9 else { return .primary }
        return .red.opacity(0.45 + 0.55 * max(0, min(1, (0.9 - confidence) / 0.9)))
    }
}
