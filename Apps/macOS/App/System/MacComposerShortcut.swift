import Carbon.HIToolbox
import LegatoMac
import LegatoAppServices
import Synchronization

/// Reserved only while the corresponding action is available. Carbon delivers the chord
/// to Legato without typing its Return or Delete into the document behind the composer.
enum MacComposerShortcut: UInt32, CaseIterable {
    case magic = 1, insert, discard, undoDiscard

    /// Magic already has a global tap/hold binding. The other actions reserve chords only
    /// while the draft can consume them.
    static let chordActions: [Self] = [.insert, .discard, .undoDiscard]

    var defaultBinding: HotkeySpec {
        switch self {
        case .magic: .modifier(.rightCommand)
        case .insert: .combo(keyCode: UInt16(kVK_RightArrow), modifiers: .command)
        case .discard: .combo(keyCode: UInt16(kVK_LeftArrow), modifiers: .command)
        case .undoDiscard: .combo(keyCode: UInt16(kVK_ANSI_Z), modifiers: .command)
        }
    }

    func accepts(_ binding: HotkeySpec) -> Bool {
        if case .combo = binding { return true }
        return self == .magic
    }

    @MainActor func isAvailable(in session: MacDictationSession, duringMagicHold: Bool = false) -> Bool {
        guard let draft = session.composer else { return false }
        switch self {
        case .undoDiscard: return draft.canUndoDiscard
        case .discard: return !draft.canUndoDiscard && !draft.isInserting && (duringMagicHold || session.phase != .starting) && (!draft.isEmpty || session.isActive)
        case .magic, .insert: return !draft.isEmpty && !draft.needsCopy && !draft.isCorrecting && !draft.isInserting
                && ((duringMagicHold && self == .insert) || (session.phase != .starting && session.speechMode != .instruction))
        }
    }

    fileprivate func register(binding: HotkeySpec, signature: OSType) -> EventHotKeyRef? {
        guard self != .magic, case let .combo(keyCode, modifiers) = binding else { return nil }
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.function) { carbonModifiers |= UInt32(kEventKeyModifierFnMask) }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: rawValue)
        guard RegisterEventHotKey(UInt32(keyCode), carbonModifiers, identifier,
                                  GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference) == noErr else { return nil }
        return reference
    }
}

@MainActor final class MacComposerShortcuts {
    nonisolated private static let signature: OSType = 0x4C674370 // LgCp
    private var handler: EventHandlerRef?
    private let active = Mutex(Set<HotkeySpec>())
    private var registered: [MacComposerShortcut: (binding: HotkeySpec, reference: EventHotKeyRef)] = [:]
    private var failures: [MacComposerShortcut: HotkeySpec] = [:]
    var perform: (MacComposerShortcut) -> Void = { _ in }

    /// A recorder can check the actual system reservation before replacing a saved chord.
    func canRegister(_ binding: HotkeySpec, for action: MacComposerShortcut) -> Bool {
        if registered[action]?.binding == binding { return true }
        guard let reference = action.register(binding: binding, signature: Self.signature) else { return false }
        UnregisterEventHotKey(reference)
        return true
    }

    /// Reports each failed reservation once for as long as that binding is requested.
    @discardableResult func update(bindings: [MacComposerShortcut: HotkeySpec]) -> [MacComposerShortcut: HotkeySpec] {
        if handler == nil && !bindings.isEmpty {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                      identifier.signature == MacComposerShortcuts.signature, let action = MacComposerShortcut(rawValue: identifier.id)
                else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    let shortcuts = Unmanaged<MacComposerShortcuts>.fromOpaque(context).takeUnretainedValue()
                    if shortcuts.registered[action] != nil { shortcuts.perform(action) }
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        // Release every changed binding first, so moving a chord between two actions can
        // register the new owner in this same update.
        for (action, entry) in registered where entry.binding != bindings[action] {
            UnregisterEventHotKey(entry.reference)
            registered.removeValue(forKey: action)
        }
        failures = failures.filter { bindings[$0.key] == $0.value }
        var newFailures: [MacComposerShortcut: HotkeySpec] = [:]
        for (action, binding) in bindings where registered[action] == nil && failures[action] == nil {
            if handler != nil, let reference = action.register(binding: binding, signature: Self.signature) {
                registered[action] = (binding, reference)
            } else {
                failures[action] = binding
                newFailures[action] = binding
            }
        }
        active.withLock { $0 = Set(registered.values.map(\.binding)) }
        return newFailures
    }

    nonisolated func owns(_ event: KeyEvent) -> Bool {
        active.withLock { $0.contains { $0.triggerEvent(for: event) == .pressed } }
    }
}
