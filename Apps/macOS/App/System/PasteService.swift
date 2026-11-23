import AppKit
import Carbon.HIToolbox
import CoreGraphics
import LegatoKeyboardCore
import LegatoMac

/// Puts dictated text on the pasteboard and, where wanted, pastes it with a synthesized ⌘V.
@MainActor
final class PasteService {
    /// Clipboard managers skip items with this marker (nspasteboard.org).
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard = NSPasteboard.general
    private var pendingRestore: (changeCount: Int, snapshot: Snapshot)?

    /// Leaves `text` on the pasteboard for the user to paste themselves.
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Posts a single staged draft to its original destination. History owns recovery when posting fails.
    /// Passwords stay off the pasteboard, including when their text would normally be pasted.
    func insert(_ text: String, targetPID: pid_t, passwordField: Bool, restoreClipboard: Bool, paced: Bool,
                canBegin: @MainActor () -> Bool, stillOwned: @MainActor () -> Bool) async -> Bool {
        let released = await ModifierWait.untilReleased(held: { !Self.modifiersReleased }, cap: .milliseconds(500))
        func canPost() -> Bool {
            guard !Task.isCancelled, Self.modifiersReleased else { return false }
            return FallbackRoute.route(
                axTrusted: AXIsProcessTrusted(),
                frontmostIsTarget: NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID && stillOwned(),
                secureField: !passwordField && IsSecureEventInputEnabled()
            ) == .pasteKeystroke
        }
        guard released, canBegin(), canPost() else { return false }
        let needsPaste = TypewriterPlan.needsPaste(text)
        // Estimates for event construction and focus checks, with headroom inside the iPhone delivery target.
        let fits = ChunkEntrance.stagedBurstFits(characterCount: text.count, estimatedWriteMs: 3)
        if !passwordField && (!paced || !fits || needsPaste) {
            return pasteOnce(text, restoreClipboard: restoreClipboard) { canPost() && canBegin() }
        }
        guard !needsPaste else { return false }
        return await type(text, paced: paced && fits, canPost: canPost)
    }

    private func pasteOnce(_ text: String, restoreClipboard: Bool, canPost: () -> Bool) -> Bool {
        let currentCount = pasteboard.changeCount
        let previous = pendingRestore.flatMap { $0.changeCount == currentCount ? $0.snapshot : nil }
        // A second quick insert should restore the pre-dictation clipboard, not the first transient draft.
        let snapshot = restoreClipboard ? previous ?? Snapshot(of: pasteboard) : nil
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        guard canPost() else { return false }
        pendingRestore = nil
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]), SyntheticKeys.commandV() else {
            snapshot?.restore(to: pasteboard)
            return false
        }
        let written = pasteboard.changeCount
        if let snapshot {
            pendingRestore = (written, snapshot)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.restoreClipboard(after: written)
            }
        }
        return true
    }

    private func restoreClipboard(after changeCount: Int) {
        guard let pendingRestore, pendingRestore.changeCount == changeCount else { return }
        self.pendingRestore = nil
        if pasteboard.changeCount == changeCount { pendingRestore.snapshot.restore(to: pasteboard) }
    }

    private func type(_ text: String, paced: Bool, canPost: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        let gap = Duration.milliseconds(ChunkEntrance.typewriterGapMs)
        let budget = Duration.milliseconds(ChunkEntrance.typewriterCapMs)
        var remaining = text[...]
        while let character = remaining.first {
            guard canPost() else { return false }
            if !paced || clock.now >= start + budget {
                // Remove the remaining animation delay if a host check ran long. Only the unsent suffix is eligible.
                return TypewriterPlan.eventChunks(String(remaining)).allSatisfy { canPost() && SyntheticKeys.type($0) }
            }
            guard SyntheticKeys.type(String(character)) else { return false }
            remaining = remaining.dropFirst()
            if !remaining.isEmpty, clock.now + gap < start + budget { try? await clock.sleep(for: gap) }
        }
        return true
    }

    private static var modifiersReleased: Bool {
        CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty
    }

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
