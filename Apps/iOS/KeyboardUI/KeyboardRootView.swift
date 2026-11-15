import LegatoKeyboardCore
import SwiftUI

/// The keyboard: the full layout (`TypingFallbackView`: the word row, the tool row and the native key grid) or
/// the compact strip (`StripView`), switched by the chevron or a swipe (`KeyboardController.toggleExpansion`).
struct KeyboardRootView: View {
    let controller: KeyboardController

    var body: some View {
        Group {
            if controller.mode == .strip {
                StripView(controller: controller)
            } else {
                TypingFallbackView(controller: controller)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.mode)
    }
}
