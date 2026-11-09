import LegatoKeyboardCore
import SwiftUI

/// The keyboard: the word row (also the instruction strip), the tool row (undo, redo, the magic key, the dictation
/// mic) and the native key grid (`TypingFallbackView`).
struct KeyboardRootView: View {
    let controller: KeyboardController

    var body: some View {
        TypingFallbackView(controller: controller)
    }
}
