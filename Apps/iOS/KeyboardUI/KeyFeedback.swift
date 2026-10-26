import UIKit

/// A light tap and the keyboard click on every key press. Both need Full Access and their setting;
/// the click also follows the system's "Keyboard Clicks" switch and needs the input view to adopt
/// `UIInputViewAudioFeedback` (the extension's does).
@MainActor
final class KeyFeedback {
    private var generator: UIImpactFeedbackGenerator?
    private var clicks = false

    /// Re-reads the settings; called whenever the keyboard appears.
    func refresh(fullAccess: Bool, preferences: KeyboardPreferences = .load()) {
        clicks = fullAccess && preferences.clicks
        if fullAccess && preferences.haptics {
            let generator = generator ?? UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            self.generator = generator
        } else {
            generator = nil
        }
    }

    func tick() {
        if let generator {
            generator.impactOccurred()
            generator.prepare()
        }
        if clicks { UIDevice.current.playInputClick() }
    }
}
