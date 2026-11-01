import SwiftUI
import UIKit

/// The globe key: a `UIButton` wired to `handleInputModeList`, which switches to the next keyboard on a
/// tap and shows the keyboard list on a long press. SwiftUI buttons can't do the long press. Shown only
/// when iOS asks for it (`needsInputModeSwitchKey`).
struct GlobeKey: UIViewRepresentable {
    weak var target: UIInputViewController?
    let typing: TypingModel
    var emoji = false

    final class Coordinator {
        weak var target: UIInputViewController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: emoji ? "face.smiling" : "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        configuration.baseForegroundColor = KeyColors.ink
        configuration.background.cornerRadius = KeyGeometry.keyRadius
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted ? KeyColors.pressed : KeyColors.key
        }
        button.accessibilityIdentifier = emoji ? "key.emoji" : "key.globe"
        button.accessibilityLabel = "Next keyboard"
        button.accessibilityHint = "Touch and hold to choose a keyboard, including Emoji if enabled."
        button.addAction(UIAction { [weak typing] _ in
            #if DEBUG
            NSLog("kbd.system-switch request=%@-picker-touch", emoji ? "emoji" : "globe")
            #endif
            typing?.feedback.tick()
        }, for: .touchDown)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let selector = #selector(UIInputViewController.handleInputModeList(from:with:))
        if let old = context.coordinator.target {
            button.removeTarget(old, action: selector, for: .allTouchEvents)
        }
        if let target { button.addTarget(target, action: selector, for: .allTouchEvents) }
        context.coordinator.target = target
        button.isEnabled = target != nil
        if target == nil { button.accessibilityHint = "Available in the installed keyboard extension." }
    }
}
