import LegatoKeyboardCore
import SwiftUI

/// The dictation key (#315), beside the transcript. A tap starts, pauses or resumes dictation; what it does comes from
/// `MicKeyMode` (see `KeyboardController.micTapped`): an explainer without Full Access, a `Link` that opens the app when it is
/// not running, a request to the running app otherwise. A swipe down minimises the keyboard, up expands it, left undoes and
/// right redoes (`DictationKeyDrag`); a drag never also taps, and never opens the app. Faint hints show the swipes for the
/// key's first few uses (`DictationKeyHints`). It fills the touch area it is given and draws the key `hitInsets` inside it.
struct MicKey: View {
    let controller: KeyboardController
    /// Touch area beyond the drawn key on each side; the frame given includes it.
    var hitInsets = EdgeInsets()

    @State private var drag = DictationKeyDrag()
    @GestureState private var down = false

    var body: some View {
        Group {
            switch controller.micMode {
            case .openApp:
                Link(destination: KeyboardURL.make(command: controller.openAppCommand, requestID: controller.openAppRequestID)) {
                    label
                }
                // The link opens the app on its own lift; a touch that swiped must not.
                .environment(\.openURL, OpenURLAction { url in drag.swiped ? .handled : .systemAction(url) })
            case .needsFullAccess, .remote:
                label
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { controller.micTapped() }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($down) { _, state, _ in state = true }
                .onChanged { value in
                    if let direction = drag.moved(startX: value.startLocation.x, startY: value.startLocation.y,
                                                  dx: value.translation.width, dy: value.translation.height) {
                        swiped(direction)
                    }
                }
                .onEnded { value in
                    guard drag.ended(dx: value.translation.width, dy: value.translation.height) == .tap else { return }
                    controller.dictationKeyUsed()
                    controller.micTapped()
                })
        .accessibilityIdentifier("key.mic")
        .accessibilityAction(named: "Undo") { if controller.canUndo { controller.undo() } }
        .accessibilityAction(named: "Redo") { if controller.canRedo { controller.redo() } }
        .accessibilityAction(named: controller.mode == .full ? "Minimise keyboard" : "Show full keyboard") {
            controller.setMode(controller.mode == .full ? .minimised : .full)
        }
    }

    private func swiped(_ direction: DictationKeyGesture.Direction) {
        let acted: Bool
        switch direction {
        case .down: acted = controller.mode == .full; controller.setMode(.minimised)
        case .up: acted = controller.mode == .minimised; controller.setMode(.full)
        case .left: acted = controller.canUndo; controller.undo()
        case .right: acted = controller.canRedo; controller.redo()
        }
        controller.dictationKeyUsed()
        if acted { controller.typing.feedback.tick() }
    }

    private var capturing: Bool { controller.isCapturing }
    private var canStop: Bool { controller.micMode == .remote(.stop) || controller.routeOpen }

    /// A native key face; while capturing, filled red with a pulsing pause glyph.
    private var label: some View {
        let ink = capturing ? Color.white : Color(uiColor: KeyColors.ink)
        return ZStack {
            RoundedRectangle(cornerRadius: KeyGeometry.keyRadius)
                .fill(capturing ? Color.red : Color(uiColor: down ? KeyColors.pressed : KeyColors.key))
            Image(systemName: canStop ? "pause.fill" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ink)
                .symbolEffect(.pulse, isActive: capturing)
            if controller.dictationKeyHints.shows { hints(ink: ink) }
        }
        .padding(hitInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Not clear: the keyboard gets no touches on fully clear pixels.
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
        .accessibilityLabel(canStop ? (capturing ? "Pause dictation" : "Cancel dictation") : "Start dictation")
        .accessibilityHint("Swipe left to undo, right to redo, down or up to resize the keyboard.")
    }

    /// The swipes, faintly at the key's edges: undo and redo at the sides, and the way to the other layout under or over the
    /// glyph (only on a key tall enough to keep it clear of the glyph: not the 27 pt landscape key).
    private func hints(ink: Color) -> some View {
        let full = controller.mode == .full
        return GeometryReader { proxy in
            ZStack {
                hint("chevron.left").frame(maxWidth: .infinity, alignment: .leading)
                hint("chevron.right").frame(maxWidth: .infinity, alignment: .trailing)
                if proxy.size.height >= Self.verticalHintHeight {
                    hint(full ? "chevron.down" : "chevron.up").frame(maxHeight: .infinity, alignment: full ? .bottom : .top)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .foregroundStyle(ink.opacity(0.3))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// The least key height with room for a vertical hint beside the 20 pt glyph.
    private static let verticalHintHeight: CGFloat = 38

    private func hint(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
    }
}
