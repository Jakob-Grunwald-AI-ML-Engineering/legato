import LegatoKeyboardCore
import SwiftUI

/// The chevron that switches between the strip and the full keyboard (`KeyboardController.toggleExpansion`):
/// up on the strip, down on the full keyboard. Drawn as a key (fill, radius, pressed
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
    var selected = false
    var insets = EdgeInsets()

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(
            RoundedRectangle(cornerRadius: KeyGeometry.keyRadius)
                .fill(Color(uiColor: configuration.isPressed || selected ? KeyColors.pressed : KeyColors.key))
                .padding(insets))
    }
}

/// A vertical swipe that expands the strip or collapses the full keyboard (`KeyboardController.swiped`). It
/// fires while the finger moves, once per drag: a swipe up leaves the strip's few points within a moment, and
/// iOS then cancels the touch, so an end-of-drag handler would never run. Attached with
/// `simultaneousGesture`, so the keys under it still get their taps.
private struct ExpansionSwipe: ViewModifier {
    let controller: KeyboardController
    /// Whether the current drag already toggled; resets when the drag ends or is cancelled.
    @GestureState private var fired = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .updating($fired) { value, fired, _ in
                    guard !fired else { return }
                    let dx = value.translation.width, dy = value.translation.height
                    guard controller.expansion.swipeToggles(dx: dx, dy: dy) else { return }
                    fired = true
                    Task { @MainActor in controller.swiped(dx: dx, dy: dy) }
                })
    }
}

extension View {
    /// Swiping up on the strip or down on the full keyboard's word and tool rows toggles the layout.
    func expansionSwipe(_ controller: KeyboardController) -> some View {
        modifier(ExpansionSwipe(controller: controller))
    }
}
