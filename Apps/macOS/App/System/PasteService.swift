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

    enum PasteOutcome {
        case pasted
        case copied(CopyReason)
    }

    /// Pastes `text` into the app the dictation started in (`targetPID`). Nothing touches the
    /// pasteboard until the hotkey's modifiers are up (a ⌘V typed while they are down would arrive
    /// as another shortcut); then the guards run again, and if any fails the text is only copied.
    /// With `restoreClipboard`, the previous pasteboard contents come back about 0.5 s after the
    /// paste, but only if nobody else wrote to it in between.
    func paste(_ text: String, restoreClipboard: Bool, targetPID: pid_t?, secureField: Bool, stillOwned: @MainActor () -> Bool = { true }) async -> PasteOutcome {
        let snapshot = restoreClipboard ? Snapshot(of: pasteboard) : nil

        let released = await waitForModifiersReleased()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let trusted = AXIsProcessTrusted()
        let secure = secureField || IsSecureEventInputEnabled()
        let onTarget = frontmost != nil && frontmost == targetPID && stillOwned()
        let route = FallbackRoute.route(
            axTrusted: trusted, frontmostIsTarget: onTarget, secureField: secure, modifiersReleased: released)
        if case .copyOnly(let reason) = route {
            copy(text)
            return .copied(reason)
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount
        Self.postCommandV()

        if let snapshot {
            Task { [pasteboard] in
                try? await Task.sleep(for: .milliseconds(500))
                if pasteboard.changeCount == ours { snapshot.restore(to: pasteboard) }
            }
        }
        return .pasted
    }

    // MARK: Typing

    enum TypeOutcome {
        /// Every character went in; control characters used individual guarded pastes.
        case typed
        /// Typing stopped (the app changed, or the user pressed a key); the caller retains the untyped rest.
        case interrupted(remainder: String)
        /// Typing was not possible because a guard failed before the first character; nothing was typed.
        case unavailable(CopyReason)
    }

    /// Types one grapheme at a time (`paced` false: without the pauses). Controls and graphemes larger than a key
    /// event use individual clipboard pastes; Return/Tab are never synthesized. One snapshot spans the sequence.
    /// `passwordField`: the take was dictated for a password field, where secure event input is expected to be on
    /// (it hides keys from other apps; posted keys still reach the field). Anywhere else secure input stops typing.
    func type(_ text: String, targetPID: pid_t?, passwordField: Bool = false, restoreClipboard: Bool = true, paced: Bool = true,
              realKeyDowns: @MainActor () -> Int, stillOwned: @MainActor () -> Bool = { true }) async -> TypeOutcome {
        let released = await waitForModifiersReleased()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let secureInputBlocks = { !passwordField && IsSecureEventInputEnabled() }
        let route = FallbackRoute.route(
            axTrusted: AXIsProcessTrusted(), frontmostIsTarget: frontmost != nil && frontmost == targetPID && stillOwned(),
            secureField: secureInputBlocks(), modifiersReleased: released)
        if case .copyOnly(let reason) = route { return .unavailable(reason) }
        guard !Task.isCancelled, let targetPID else { return .unavailable(.appChanged) }
        let baseline = realKeyDowns()
        var snapshot: Snapshot?
        var clipboardCount: Int?
        let result = await Typewriter.run(text, sleep: { if paced { try? await Task.sleep(for: $0) } }, writeAsync: { [self] step in
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            guard !Task.isCancelled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
                  !secureInputBlocks(), stillOwned(), realKeyDowns() == baseline,
                  CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else { return false }
            guard TypewriterPlan.needsPaste(step) else { return Self.postUnicode(step) }
            // A clipboard changed by the user or another app belongs to them; do not overwrite it
            // with another automated control paste midway through this sequence.
            if let clipboardCount, pasteboard.changeCount != clipboardCount { return false }
            if restoreClipboard, snapshot == nil { snapshot = Snapshot(of: pasteboard) }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(step, forType: .string)
            item.setData(Data(), forType: Self.transientType)
            guard pasteboard.writeObjects([item]) else { return false }
            clipboardCount = pasteboard.changeCount
            Self.postCommandV()
            // The target consumes the paste asynchronously. Keep this control on the clipboard
            // until it has had the same consumption window as an ordinary guarded paste.
            try? await Task.sleep(for: .milliseconds(500))
            return true
        })
        guard let remainder = result.remainder else {
            if let snapshot, let clipboardCount, pasteboard.changeCount == clipboardCount {
                snapshot.restore(to: pasteboard)
            }
            return .typed
        }
        guard result.wroteAny else {
            if let snapshot, let clipboardCount, pasteboard.changeCount == clipboardCount {
                snapshot.restore(to: pasteboard)
            }
            return .unavailable(.appChanged)
        }
        if let snapshot, let clipboardCount, pasteboard.changeCount == clipboardCount {
            snapshot.restore(to: pasteboard)
        }
        return .interrupted(remainder: remainder)
    }

    /// One step as key events of at most 20 UTF-16 units each: key down and up, no modifiers, tagged as ours.
    static func postUnicode(_ text: String) -> Bool {
        TypewriterPlan.eventChunks(text).allSatisfy { SyntheticKeys.type($0) }
    }

    // MARK: Keystroke

    /// Waits for the hotkey's modifiers to come up (the hotkey release), up to `ModifierWait.cap`; false if they are
    /// still held. Reads the hardware state, which synthesized events do not change.
    private func waitForModifiersReleased() async -> Bool {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return await ModifierWait.untilReleased(held: { !CGEventSource.flagsState(.hidSystemState).intersection(mask).isEmpty })
    }

    /// ⌘V, paired (`SyntheticKeys.commandV`).
    static func postCommandV() { SyntheticKeys.commandV() }

    // MARK: Snapshot

    /// Every item with every type it offers, read eagerly (promised data is forced now).
    struct Snapshot {
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
