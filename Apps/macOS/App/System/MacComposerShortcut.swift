import Carbon.HIToolbox
import LegatoMac
import LegatoAppServices
import Synchronization

/// Reserved only while the corresponding action is available. Carbon delivers the chord
/// to Legato without typing its Return or Delete into the document behind the composer.
enum MacComposerShortcut: UInt32, CaseIterable {
    case magic = 1, insert, discard, undoDiscard

    private var keyCode: UInt16 {
        switch self {
        case .magic: UInt16(kVK_ANSI_M)
        case .insert: UInt16(kVK_Return)
        case .discard: UInt16(kVK_Delete)
        case .undoDiscard: UInt16(kVK_ANSI_Z)
        }
    }
    var spec: HotkeySpec { .combo(keyCode: keyCode, modifiers: [.control, .option]) }
    var keysLabel: String { spec.displayName }

    @MainActor func isAvailable(in session: MacDictationSession) -> Bool {
        guard let draft = session.composer else { return false }
        switch self {
        case .undoDiscard: return draft.canUndoDiscard
        case .discard: return !draft.canUndoDiscard && !draft.isInserting && session.phase != .starting && (!draft.isEmpty || session.isActive)
        case .magic, .insert: return !draft.isEmpty && !draft.needsCopy && !draft.isCorrecting && !draft.isInserting
                && session.phase != .starting && session.speechMode != .instruction
        }
    }

    fileprivate func register(signature: OSType) -> EventHotKeyRef? {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: rawValue)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey), identifier,
                                  GetApplicationEventTarget(), 0, &reference) == noErr else { return nil }
        return reference
    }
}

@MainActor final class MacComposerShortcuts {
    nonisolated private static let signature: OSType = 0x4C674370 // LgCp
    private var handler: EventHandlerRef?
    private let active = Mutex(Set<MacComposerShortcut>())
    private var registered: [MacComposerShortcut: EventHotKeyRef] = [:]
    var perform: (MacComposerShortcut) -> Void = { _ in }

    func update(available: Set<MacComposerShortcut>) {
        if handler == nil && !available.isEmpty {
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
        guard handler != nil else { return }
        for action in MacComposerShortcut.allCases {
            if available.contains(action) {
                if registered[action] == nil { registered[action] = action.register(signature: Self.signature) }
            } else if let reference = registered.removeValue(forKey: action) {
                UnregisterEventHotKey(reference)
            }
        }
        active.withLock { $0 = Set(registered.keys) }
    }

    nonisolated func owns(_ event: KeyEvent) -> Bool {
        active.withLock { $0.contains { $0.spec.triggerEvent(for: event) == .pressed } }
    }
}
