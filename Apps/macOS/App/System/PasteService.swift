import AppKit
import CoreGraphics

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

    /// Pastes `text` into the frontmost app. With `restoreClipboard`, the previous pasteboard
    /// contents come back about 0.5 s later, but only if nobody else wrote to it in between.
    func paste(_ text: String, restoreClipboard: Bool) async {
        let snapshot = restoreClipboard ? Snapshot(of: pasteboard) : nil

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount

        await waitForModifiersReleased()
        postCommandV()

        guard let snapshot else { return }
        Task { [pasteboard] in
            try? await Task.sleep(for: .milliseconds(500))
            if pasteboard.changeCount == ours { snapshot.restore(to: pasteboard) }
        }
    }

    // MARK: Keystroke

    /// A synthesized ⌘V while the hotkey's modifier is still down would arrive as ⌘⌥V and the like.
    private func waitForModifiersReleased() async {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = ContinuousClock.now + .seconds(1)
        while !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
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
