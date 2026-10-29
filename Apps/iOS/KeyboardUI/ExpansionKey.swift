import SwiftUI

/// The chevron that switches between the strip and the full keyboard (`KeyboardController.toggleExpansion`):
/// up on the strip, down on the full keyboard of a strip session. Drawn as a key (fill, radius, pressed
/// color); fills the frame it is given.
struct ExpansionKey: View {
    let controller: KeyboardController
    let symbol: String
    /// The key is drawn this far inside the frame; the frame around it still takes the touch.
    var insets = EdgeInsets()

    var body: some View {
        Button { controller.toggleExpansion() } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(uiColor: KeyColors.ink))
                .padding(insets)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.001))
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyButtonStyle(insets: insets))
        .accessibilityLabel(symbol == "chevron.up" ? "Show full keyboard" : "Show compact keyboard")
        .accessibilityIdentifier("key.expand")
    }
}

/// A key's look for a SwiftUI button: the key fill, the pressed fill while held, the key radius.
struct KeyButtonStyle: ButtonStyle {
    var insets = EdgeInsets()

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(
            RoundedRectangle(cornerRadius: KeyGeometry.keyRadius)
                .fill(Color(uiColor: configuration.isPressed ? KeyColors.pressed : KeyColors.key))
                .padding(insets))
    }
}
