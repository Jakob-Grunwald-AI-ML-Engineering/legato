import LegatoKeyboardCore
import SwiftUI

/// The magic key: instruction mode. A tap latches it on and off; holding it keeps it on only while the finger is
/// down. Either way speech is an instruction while it is on, and turning it off runs the instruction
/// (`KeyboardController.engageMagic` / `releaseMagic`). It opens the mic if the mic is not open. It fills the frame
/// it is given and is filled in the accent color while on.
struct MagicKey: View {
    let controller: KeyboardController

    /// This press has become a hold. It stays set until the next press, so the tap that ends the touch can tell.
    @State private var held = false
    /// The key was latched when this press began: the press is a tap off, never a hold.
    @State private var startedLatched = false
    @State private var holdTimer: Task<Void, Never>?

    /// How long the finger stays down before the press is a hold rather than a tap.
    private static let holdDelay = Duration.milliseconds(300)

    var body: some View {
        let magic = controller.magic
        let on = magic.isOn
        StripKey(
            insets: EdgeInsets(),
            fill: on ? KeyColors.accent : KeyColors.key,
            pressedFill: on ? KeyColors.accent.withAlphaComponent(0.7) : KeyColors.pressed,
            onPress: press, onRelease: release, onTap: tap
        ) { _ in
            Image(systemName: on ? "wand.and.stars.inverse" : "wand.and.stars")
                .font(.system(size: 19, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color(uiColor: KeyColors.ink))
                .symbolEffect(.pulse, isActive: magic == .held)
                // A latched key shows a bar under the wand: it stays on without a finger.
                .overlay(alignment: .bottom) {
                    if magic == .latched { Capsule().fill(Color.white).frame(width: 14, height: 3).offset(y: 12) }
                }
        }
        .accessibilityElement()
        .accessibilityLabel("Instruction mode")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityHint(on ? "Runs the instruction you spoke." : "Turns on, then speak what to change. Touch and hold to speak while held.")
        .accessibilityAddTraits([.isButton, .isToggle])
        .accessibilityIdentifier("key.magic")
        .accessibilityAction { tap() }
    }

    private func press() {
        controller.typing.feedback.tick()
        held = false
        startedLatched = controller.magic == .latched
        holdTimer?.cancel()
        guard !startedLatched else { return }
        holdTimer = Task {
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled else { return }
            held = true
            controller.engageMagic(.held)
        }
    }

    /// The touch is over, however it ended: a hold lets go (the instruction runs).
    private func release() {
        holdTimer?.cancel(); holdTimer = nil
        if held, controller.magic == .held { controller.releaseMagic() }
    }

    private func tap() {
        guard !held else { return }
        if controller.magic.isOn { controller.releaseMagic() } else { controller.engageMagic(.latched) }
    }
}
