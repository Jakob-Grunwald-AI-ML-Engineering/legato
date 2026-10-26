import SwiftUI
import UIKit

/// The globe key: a `UIButton` wired to `handleInputModeList`, which switches to the next keyboard on a
/// tap and shows the keyboard list on a long press. SwiftUI buttons can't do the long press. Shown only
/// when iOS asks for it (`needsInputModeSwitchKey`).
struct GlobeKey: UIViewRepresentable {
    weak var target: UIInputViewController?
    let typing: TypingModel

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        configuration.baseForegroundColor = KeyColors.ink
        configuration.background.cornerRadius = KeyGeometry.keyRadius
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted ? KeyColors.pressed : KeyColors.key
        }
        button.accessibilityIdentifier = "key.globe"
        button.accessibilityLabel = "Next keyboard"
        if let target {
            button.addTarget(target, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        button.addAction(UIAction { [weak typing] _ in typing?.feedback.tick() }, for: .touchDown)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}
