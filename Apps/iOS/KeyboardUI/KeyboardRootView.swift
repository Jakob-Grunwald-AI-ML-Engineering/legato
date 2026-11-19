import LegatoKeyboardCore
import SwiftUI

/// The keyboard: the full layout (`TypingFallbackView`: the top row and the native key grid) or the minimised one
/// (`MinimisedKeyboardView`), switched by the dictation key's swipes (`KeyboardController.setMode`).
struct KeyboardRootView: View {
    let controller: KeyboardController

    var body: some View {
        Group {
            if controller.mode == .minimised {
                MinimisedKeyboardView(controller: controller)
            } else {
                TypingFallbackView(controller: controller)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.mode)
    }
}
