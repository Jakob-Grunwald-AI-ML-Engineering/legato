import AppKit
import QuartzCore
import SwiftUI
import LegatoMac
import LegatoAgent
import LegatoAppServices
import LegatoComposerUI

/// Mouse interaction never transfers keyboard focus away from the captured editor.
private final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class NotchPanelController {
    private var panel: NSPanel?
    private var screen: NSScreen?
    func show(controller: MacAppController, targetPID: pid_t?) {
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: NotchComposerView(controller: controller, attached: screen.safeAreaInsets.top > 0, resize: resize))
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
    func hide() { panel?.orderOut(nil) }
    private func resize(_ height: CGFloat) {
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

private struct NotchComposerView: View {
    let controller: MacAppController
    let attached: Bool
    let resize: (CGFloat) -> Void
    private var session: ComposerSession { controller.composer }
    private var contentHeight: CGFloat {
        let rows = session.snapshot.lines.reduce(0) { count, line in
            count + max(1, Int(ceil(Double(line.words.map(\.text).joined(separator: " ").count) / 58)))
        }
        let tailRows = session.tail.isEmpty ? 0 : max(1, Int(ceil(Double(session.tail.count) / 58)))
        return min(440, max(188, 138 + CGFloat(rows + tailRows) * 23 + CGFloat(max(0, session.snapshot.lines.count - 1)) * 12 + (session.error == nil ? 0 : 42)))
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: session.isListening ? "mic.fill" : "waveform")
                    .foregroundStyle(session.isListening ? Color.red : Color.secondary)
                Text(session.status.capitalized).font(.headline)
                Spacer()
                Menu(session.mode.rawValue.capitalized) {
                    ForEach(ComposerMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue.capitalized) { Task { await session.setMode(mode) } }
                    }
                }.fixedSize()
            }
            ComposerView(snapshot: session.snapshot, tail: session.tail, pendingLineIDs: session.pendingLineIDs, busy: session.busy,
                onWordTap: { line, word in Task { await session.tap(lineID: line, wordID: word) } },
                onPick: { line, word, text in Task { await session.pick(lineID: line, wordID: word, text: text) } })
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2).help(error).textSelection(.disabled) }
            HStack {
                Button("Cancel") { controller.cancelComposer() }
                Button("Undo", systemImage: "arrow.uturn.backward") { Task { await session.undo() } }
                Spacer()
                if session.isListening { Button("Stop", systemImage: "stop.fill") { controller.stopComposer() } }
                Button("Insert", systemImage: "arrow.down.to.line") { controller.insertComposer() }
                    .buttonStyle(.borderedProminent).disabled(session.renderedText.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.075, green: 0.075, blue: 0.085), in: UnevenRoundedRectangle(topLeadingRadius: attached ? 14 : 20, bottomLeadingRadius: 22, bottomTrailingRadius: 22, topTrailingRadius: attached ? 14 : 20))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: attached ? 14 : 20, bottomLeadingRadius: 22, bottomTrailingRadius: 22, topTrailingRadius: attached ? 14 : 20))
        .onAppear { resize(contentHeight) }
        .onChange(of: contentHeight) { _, height in resize(height) }
        .environment(\.colorScheme, .dark)
    }
}
