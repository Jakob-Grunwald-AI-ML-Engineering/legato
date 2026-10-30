import SwiftUI
public struct ModeChip: View {
    public var mode: String
    public var onChange: (String) -> Void
    public init(mode: String, onChange: @escaping (String) -> Void) { self.mode = mode; self.onChange = onChange }
    private let modes = ["message", "email", "prompt", "note"]
    public var body: some View {
        Button(mode.capitalized) { advance(1) }.font(.caption.bold()).buttonStyle(.bordered)
            .gesture(DragGesture(minimumDistance: 15).onEnded { value in if abs(value.translation.width) > abs(value.translation.height) { advance(value.translation.width < 0 ? 1 : -1) } })
            .accessibilityHint("Swipe left or right to change writing mode")
    }
    private func advance(_ step: Int) { let i = modes.firstIndex(of: mode) ?? 0; onChange(modes[(i + step + modes.count) % modes.count]) }
}
