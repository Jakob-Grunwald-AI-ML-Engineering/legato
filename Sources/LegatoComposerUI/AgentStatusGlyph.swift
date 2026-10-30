import SwiftUI
public struct AgentStatusGlyph: View {
    public init() {}
    public var body: some View { Image(systemName: "sparkles").foregroundStyle(.tint).symbolEffect(.pulse).accessibilityLabel("Agent editing") }
}
