/// Keeps each captured press paired with its release, even when the activity closes or
/// the shortcut configuration changes between them. Lives on the event tap thread.
public struct ActivityHotkeyCapture: Sendable {
    public enum Decision: Equatable, Sendable {
        case pass, capture, suppressRepeat
    }

    private var keys: Set<UInt16> = []
    public private(set) var modifiers: Set<ModifierKey> = []

    public init() {}

    public mutating func route(_ event: KeyEvent, matches: Bool, isRepeat: Bool) -> Decision {
        switch event.kind {
        case .keyDown:
            if keys.contains(event.keyCode) { return .suppressRepeat }
            guard matches, !isRepeat else { return .pass }
            keys.insert(event.keyCode)
            return .capture
        case .keyUp:
            return keys.remove(event.keyCode) == nil ? .pass : .capture
        case .flagsChanged:
            guard let change = event.changedModifier else { return .pass }
            if !change.isDown {
                return modifiers.remove(change.key) == nil ? .pass : .capture
            }
            if modifiers.contains(change.key) { return .suppressRepeat }
            guard matches else { return .pass }
            modifiers.insert(change.key)
            return .capture
        }
    }

    public mutating func reset() {
        keys.removeAll()
        modifiers.removeAll()
    }
}
