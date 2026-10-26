import SwiftUI

/// The chevron that switches between the strip and the full keyboard (`KeyboardController.toggleExpansion`):
/// up on the strip, down on the full keyboard of a strip session. Fills the frame it is given.
struct ExpansionKey: View {
    let controller: KeyboardController
    let symbol: String

    var body: some View {
        Button { controller.toggleExpansion() } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "chevron.up" ? "Show full keyboard" : "Show compact keyboard")
        .accessibilityIdentifier("key.expand")
    }
}
