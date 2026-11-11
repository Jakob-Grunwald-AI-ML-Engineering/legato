import AppKit
import Carbon.HIToolbox
import CoreGraphics
import LegatoMac

/// Every key event Legato posts goes through here. A sequence is built completely before anything is posted, and
/// only a balanced one (`SyntheticEvent.isBalanced`: every key-down with its key-up, never Return or Tab) goes out, so
/// a failure can never leave a key or modifier held down. Each event is tagged as Legato's (`SyntheticEvent.userData`).
enum SyntheticKeys {
    struct Stroke {
        var key: CGKeyCode
        var down: Bool
        var flags: CGEventFlags = []
        var unicode: [UniChar]?
    }

    /// Posts all of `strokes` or none.
    @discardableResult
    static func post(_ strokes: [Stroke]) -> Bool {
        guard SyntheticEvent.isBalanced(strokes.map { (key: UInt16($0.key), down: $0.down) }) else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        var events: [CGEvent] = []
        for stroke in strokes {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.key, keyDown: stroke.down) else { return false }
            event.flags = stroke.flags
            if let unicode = stroke.unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.userData)
            events.append(event)
        }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// One key pressed and released, no modifiers.
    @discardableResult
    static func tap(_ key: Int) -> Bool {
        post([Stroke(key: CGKeyCode(key), down: true), Stroke(key: CGKeyCode(key), down: false)])
    }

    /// `text` (at most one key event's worth, no control characters) as one Unicode key down and up, no modifiers.
    @discardableResult
    static func type(_ text: String) -> Bool {
        guard SyntheticEvent.typeable(text) else { return false }
        let units = Array(text.utf16)
        return post([Stroke(key: 0, down: true, unicode: units), Stroke(key: 0, down: false, unicode: units)])
    }

    /// ⌘V as a real keyboard sends it: Command down, V down and up, Command up. Posting only V with the Command flag
    /// left the HID state's Command flag set, so the user's next keys arrived as shortcuts.
    @discardableResult
    static func commandV() -> Bool {
        let command = CGKeyCode(kVK_Command), v = CGKeyCode(kVK_ANSI_V)
        return post([Stroke(key: command, down: true, flags: .maskCommand), Stroke(key: v, down: true, flags: .maskCommand),
                     Stroke(key: v, down: false, flags: .maskCommand), Stroke(key: command, down: false)])
    }
}

/// The user's real key presses and clicks, counted on the event tap's thread as they happen (Legato's own synthetic
/// keys are not counted). A key planned at one count is refused at another.
final class RealInput: @unchecked Sendable {
    static let shared = RealInput()
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value &+= 1 } }
}
