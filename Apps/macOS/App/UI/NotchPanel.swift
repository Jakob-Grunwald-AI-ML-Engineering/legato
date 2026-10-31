import AppKit
import QuartzCore
import SwiftUI
import LegatoMac
import LegatoAgent
import LegatoAppServices
import LegatoComposerUI

/// Opening preserves the editor; clicking the panel enables its local keyboard shortcuts.
private final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var handleShortcut: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { makeKey() }
        if event.type == .keyDown, handleShortcut?(event) == true { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if handleShortcut?(event) != true { super.keyDown(with: event) }
    }
}

private final class ComposerHostingView: NSHostingView<NotchComposerView> {
    override var needsPanelToBecomeKey: Bool { true }
}

@MainActor final class NotchPanelController: NSObject {
    private var panel: ComposerPanel?
    private var presentationGeneration = 0
    private var sending = false
    private var screen: NSScreen?
    func show(controller: MacAppController, targetPID: pid_t?) {
        presentationGeneration += 1; sending = false
        let screen = targetScreen(pid: targetPID) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        self.screen = screen
        let frame = NotchGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, height: 188)
        let panel = self.panel ?? ComposerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.handleShortcut = { [weak controller] event in
            guard let controller else { return false }
            return ComposerShortcut.handle(event, controller: controller)
        }
        panel.contentView = ComposerHostingView(rootView: NotchComposerView(controller: controller, attached: screen.safeAreaInsets.top > 0, resize: resize))
        panel.setFrame(frame.offsetBy(dx: 0, dy: 24), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.12)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }
    func hide() { presentationGeneration += 1; sending = false; panel?.orderOut(nil) }
    /// Preserve the same hosting view so its acknowledged draft can fly out after focus handoff.
    func revealForSend() -> Int? {
        guard let panel else { return nil }
        sending = true
        panel.orderFrontRegardless()
        return presentationGeneration
    }
    func finishSend(_ generation: Int, ifUnchanged: @escaping @MainActor () -> Bool) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard let self, generation == presentationGeneration else { return }
            sending = false
            guard panel?.isKeyWindow != true, ifUnchanged() else { return }
            hide()
        }
    }
    private weak var modeController: MacAppController?
    func showModes(controller: MacAppController) {
        guard let panel else { return }
        modeController = controller
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, mode) in ComposerMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.rawValue.capitalized, action: #selector(pickMode(_:)), keyEquivalent: String(index + 1))
            item.target = self
            item.keyEquivalentModifierMask = .command
            item.representedObject = mode.rawValue
            item.state = controller.composer.mode == mode ? .on : .off
            item.image = NSImage(systemSymbolName: modeIcon(mode), accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let topic = NSMenuItem(title: "New topic", action: #selector(startNewTopic(_:)), keyEquivalent: "")
        topic.subtitle = "Clear draft and context"
        topic.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil)
        topic.target = self
        menu.addItem(topic)
        menu.popUp(positioning: nil, at: NSPoint(x: panel.frame.minX + 14, y: panel.frame.minY + 12), in: nil)
    }
    @objc private func startNewTopic(_ item: NSMenuItem) {
        guard let controller = modeController else { return }
        Task { await controller.composer.startNewTopic() }
    }
    @objc private func pickMode(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let mode = ComposerMode(rawValue: raw), let controller = modeController else { return }
        Task { await controller.composer.setMode(mode) }
    }
    private func resize(_ height: CGFloat) {
        guard !sending else { return }
        guard let panel, let screen else { return }
        let frame = NotchGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top, height: height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().setFrame(frame, display: true)
        }
    }
    private func targetScreen(pid: pid_t?) -> NSScreen? {
        guard let pid,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let primary = NSScreen.screens.first else { return nil }
        let appKitRect = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        return NSScreen.screens.max { a, b in
            let x = a.frame.intersection(appKitRect), y = b.frame.intersection(appKitRect)
            return x.width * x.height < y.width * y.height
        }
    }
}

private func modeIcon(_ mode: ComposerMode) -> String {
    switch mode { case .message: "message"; case .email: "envelope"; case .prompt: "sparkles"; case .note: "note.text"; case .auto: "wand.and.stars"; @unknown default: "wand.and.stars" }
}

@MainActor private enum ComposerShortcut {
    static func handle(_ event: NSEvent, controller: MacAppController) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let session = controller.composer
        if event.keyCode == 53, flags.isEmpty { controller.cancelComposer(); return true }
        if event.keyCode == 36, flags == .command { controller.insertComposer(origin: .macShortcut); return true }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, let index = Int(key), (1...ComposerMode.allCases.count).contains(index) {
            Task { await session.setMode(ComposerMode.allCases[index - 1]) }; return true
        }
        if key == "z", flags == .command { Task { await session.undo() }; return true }
        if key == "z", flags == [.command, .shift] { return true } // Redo is not supported by the document yet.
        if key == "m", flags == [.command, .shift] {
            Task { await session.setInputMode(session.inputMode.toggled) }; return true
        }
        if key == "d", flags == [.command, .shift] { controller.toggle(); return true }
        return false
    }
}

private struct NotchComposerView: View {
    let controller: MacAppController
    let attached: Bool
    let resize: (CGFloat) -> Void
    @State private var showingModes = false
    @State private var showingCorrection = false
    private var session: ComposerSession { controller.composer }
    private var contentHeight: CGFloat {
        let rows = session.snapshot.lines.reduce(0) { count, line in
            count + max(1, Int(ceil(Double(line.words.map(\.text).joined(separator: " ").count) / 58)))
        }
        let tailRows = session.tail.isEmpty ? 0 : max(1, Int(ceil(Double(session.tail.count) / 58)))
        let showsInstruction = !session.instructionPreview.isEmpty && session.instructionStatus != "Done"
        let commentSpace: CGFloat = showingCorrection || showsInstruction ? 104 : 0
        return min(440, max(showingCorrection || showsInstruction ? 300 : 200, 170 + commentSpace + CGFloat(rows + tailRows) * 23 + CGFloat(max(0, session.snapshot.lines.count - 1)) * 12 + (session.error == nil ? 0 : 42)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("Composer").font(.system(size: 12, weight: .semibold))
                Spacer()
                Circle().fill(session.isListening && !session.isMuted ? Color.red : Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
                Text(session.isListening && session.inputMode == .instructions ? "Instructions" : session.status.capitalized)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            DraftInputHeader(active: session.inputMode == .dictation) {
                Task { await session.setInputMode(.dictation) }
            }
            ComposerView(snapshot: session.snapshot, tail: session.tail, dictationRevision: session.dictationRevision, dictationCommit: session.dictationCommit, successfulInsertionID: session.successfulInsertionID, pendingLineIDs: session.pendingLineIDs, busy: session.busy,
                instructionText: session.instructionPreview, instructionStatus: session.instructionStatus,
                instructionInputActive: session.inputMode == .instructions,
                correctionDraft: session.correctionDraft, correctionSubmitting: session.correctionSubmitting,
                correctionCountdownStart: session.correctionCountdownStart, correctionCountdownDeadline: session.correctionCountdownDeadline,
                onSelect: { selection in showingCorrection = true; Task { await session.select(lineID: selection.lineID, wordID: selection.wordID, endLineID: selection.endLineID, endWordID: selection.endWordID) } },
                onDeselect: { showingCorrection = false; Task { await session.clearSelection() } },
                onSendCorrection: { Task { await session.sendCorrection() } },
                onSendInstruction: { Task { await session.sendInstruction() } },
                onDiscardInstruction: { Task { await session.discardInstruction() } },
                onPick: { line, word, text in Task { await session.pick(lineID: line, wordID: word, text: text) } })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2).help(error).textSelection(.disabled) }
            HStack(spacing: 6) {
                Button {
                    showingModes = true
                    controller.notch.showModes(controller: controller)
                    showingModes = false
                } label: {
                    ComposerKeyLabel(title: session.mode.rawValue.capitalized, symbol: modeIcon(session.mode), shortcut: "⌘1–\(ComposerMode.allCases.count)")
                }
                .buttonStyle(ComposerKeyStyle(prominent: false, selected: showingModes)).frame(width: 90)
                .help("Choose writing mode (⌘1–\(ComposerMode.allCases.count))")
                key("Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z", enabled: session.canUndo) { Task { await session.undo() } }
                key("Redo", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", enabled: false) {}
                    .help("Redo is not available yet")
                key("Insert", symbol: "paperplane.fill", shortcut: "⌘↩", enabled: !controller.inserting && (!session.renderedText.isEmpty || !session.tail.isEmpty), prominent: true) { controller.insertComposer() }
                key("Cancel", symbol: "xmark", shortcut: "esc") { controller.cancelComposer() }
                key(session.inputMode == .instructions ? "Instructions" : "Dictation", symbol: session.inputMode == .instructions ? "text.bubble.fill" : "waveform", shortcut: "⇧⌘M", selected: session.inputMode == .instructions, iconOnly: true) {
                    Task { await session.setInputMode(session.inputMode.toggled) }
                }
                key(controller.isDictating ? "Pause" : (session.status == "paused" ? "Resume" : "Dictate"), symbol: controller.isDictating ? "pause.fill" : "mic.fill", shortcut: "⇧⌘D", selected: session.isListening && !session.isMuted) { controller.toggle() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.085, green: 0.085, blue: 0.095), in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        .clipShape(shape)
        .onAppear { resize(contentHeight) }
        .onChange(of: contentHeight) { _, height in resize(height) }
        .environment(\.colorScheme, .dark)
    }
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: attached ? 14 : 20, bottomLeadingRadius: 22, bottomTrailingRadius: 22, topTrailingRadius: attached ? 14 : 20)
    }
    private func key(_ title: String, symbol: String, shortcut: String, enabled: Bool = true, prominent: Bool = false, selected: Bool = false, iconOnly: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { ComposerKeyLabel(title: title, symbol: symbol, shortcut: shortcut, iconOnly: iconOnly) }
            .buttonStyle(ComposerKeyStyle(prominent: prominent, selected: selected))
            .disabled(!enabled).help("\(title) (\(shortcut))")
            .accessibilityLabel(title)
    }
}

private struct ComposerKeyLabel: View {
    let title: String
    let symbol: String
    let shortcut: String
    var iconOnly = false
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                if !iconOnly { Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1) }
            }
            Text(shortcut).font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.vertical, 1)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
        }.frame(maxWidth: .infinity).frame(height: 49).contentShape(Rectangle())
    }
}

private struct ComposerKeyStyle: ButtonStyle {
    let prominent: Bool
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        ComposerKeySurface(configuration: configuration, prominent: prominent, selected: selected, enabled: enabled)
    }
}

private struct ComposerKeySurface: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let selected: Bool
    let enabled: Bool
    @State private var hovering = false
    var body: some View {
        configuration.label
            .foregroundStyle(prominent && enabled ? Color.white : Color.primary)
            .background(background, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(enabled ? 0.11 : 0.04), lineWidth: 0.5) }
            .opacity(enabled ? 1 : 0.3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
    private var background: Color {
        if prominent && enabled { return Color.accentColor.opacity(configuration.isPressed ? 0.65 : hovering ? 1 : 0.85) }
        if selected { return Color.accentColor.opacity(0.22) }
        return .white.opacity(configuration.isPressed ? 0.15 : hovering && enabled ? 0.12 : 0.065)
    }
}
