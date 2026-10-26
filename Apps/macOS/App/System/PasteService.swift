import AppKit
import Carbon.HIToolbox
import CoreGraphics
import LegatoMac

/// Puts dictated text on the pasteboard and, where wanted, pastes it with a synthesized ⌘V.
@MainActor
final class PasteService {
    /// Clipboard managers skip items with this marker (nspasteboard.org).
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard = NSPasteboard.general

    /// Leaves `text` on the pasteboard for the user to paste themselves.
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Why a paste became a plain copy.
    enum CopyReason {
        case accessibilityMissing, secureField, appChanged, modifiersHeld

        var toast: String {
            switch self {
            case .accessibilityMissing: "Copied to the clipboard. Grant Accessibility to type into fields."
            case .secureField: "Secure field: copied to the clipboard, not typed."
            case .appChanged: "You switched apps: copied to the clipboard, paste with ⌘V."
            case .modifiersHeld: "Keys were still held: copied to the clipboard, paste with ⌘V."
            }
        }
    }

    enum PasteOutcome {
        case pasted
        case copied(CopyReason)
    }

    /// Pastes `text` into the app the dictation started in (`targetPID`). Nothing touches the
    /// pasteboard until the hotkey's modifiers are up (a ⌘V typed while they are down would arrive
    /// as another shortcut); then the guards run again, and if any fails the text is only copied.
    /// With `restoreClipboard`, the previous pasteboard contents come back about 0.5 s after the
    /// paste, but only if nobody else wrote to it in between.
    func paste(_ text: String, restoreClipboard: Bool, targetPID: pid_t?, secureField: Bool) async -> PasteOutcome {
        let snapshot = restoreClipboard ? Snapshot(of: pasteboard) : nil

        let released = await waitForModifiersReleased()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let trusted = AXIsProcessTrusted()
        let secure = secureField || IsSecureEventInputEnabled()
        let onTarget = frontmost != nil && frontmost == targetPID
        let route = FallbackRoute.route(
            axTrusted: trusted, frontmostIsTarget: onTarget, secureField: secure, modifiersReleased: released)
        guard route == .pasteKeystroke else {
            copy(text)
            if !trusted { return .copied(.accessibilityMissing) }
            if secure { return .copied(.secureField) }
            if !onTarget { return .copied(.appChanged) }
            return .copied(.modifiersHeld)
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount
        postCommandV()

        if let snapshot {
            Task { [pasteboard] in
                try? await Task.sleep(for: .milliseconds(500))
                if pasteboard.changeCount == ours { snapshot.restore(to: pasteboard) }
            }
        }
        return .pasted
    }

    // MARK: Keystroke

    /// Waits up to a second for the hotkey's modifiers to come up; false if they are still held.
    private func waitForModifiersReleased() async -> Bool {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        func held() -> Bool { !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty }
        let deadline = ContinuousClock.now + .seconds(1)
        while held(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !held()
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9 // kVK_ANSI_V
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Snapshot

    /// Every item with every type it offers, read eagerly (promised data is forced now).
    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(of pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                var types: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { types[type] = data }
                }
                return types
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored = items.map { types -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }
}
