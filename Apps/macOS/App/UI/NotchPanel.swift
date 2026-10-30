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
    func show(controller: MacAppController, targetPID: pid_t?) {
        let screen = targetScreen(pid: targetPID) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = NotchGeometry.frame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
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
        panel.contentView = NSHostingView(rootView: NotchComposerView(controller: controller))
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
    private var session: ComposerSession { controller.composer }
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
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.disabled) }
            HStack {
                Button("Cancel") { controller.cancelComposer() }
                Button("Undo", systemImage: "arrow.uturn.backward") { Task { await session.undo() } }
                Spacer()
                if session.isListening { Button("Stop", systemImage: "stop.fill") { controller.stopComposer() } }
                Button("Insert", systemImage: "arrow.down.to.line") { controller.insertComposer() }
                    .buttonStyle(.borderedProminent).disabled(session.renderedText.isEmpty)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.94), in: UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
        .environment(\.colorScheme, .dark)
    }
}
