import AppKit
import LegatoMeetings
import SwiftUI

/// The recorder shrunk to a floating capsule: the timer, mute, pause and end. It floats above other apps
/// and never takes keyboard focus from them.
private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MeetingPillPanelController {
    private let meetings: MeetingController
    private var panel: NSPanel?

    init(meetings: MeetingController) { self.meetings = meetings }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.maxY - panel.frame.height - 16))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 48),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: MeetingPill(meetings: meetings))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }
}

struct MeetingPill: View {
    let meetings: MeetingController
    @State private var confirmingEnd = false

    var body: some View {
        let state = meetings.pillState
        HStack(spacing: 10) {
            Circle()
                .fill(state.paused ? Color.orange : Color.red)
                .frame(width: 9, height: 9)
                .opacity(state.paused ? 1 : 0.9)
            Text(MeetingListLogic.clock(meetings.elapsed))
                .font(.system(.body, design: .rounded).monospacedDigit().weight(.medium))
            Text(state.label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            button(meetings.isMuted ? "mic.slash.fill" : "mic.fill", help: meetings.isMuted ? "Unmute" : "Mute") {
                meetings.toggleManualMute()
            }
            button(state.paused ? "play.fill" : "pause.fill", help: state.paused ? "Resume" : "Pause") {
                meetings.togglePause()
            }
            if confirmingEnd {
                Button("End?") { Task { await meetings.stop() } }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                    .disabled(!state.controlsEnabled)
            } else {
                button("stop.fill", help: "End the meeting") {
                    confirmingEnd = true
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        confirmingEnd = false
                    }
                }
            }
            button("arrow.up.left.and.arrow.down.right", help: "Open the meeting window") { meetings.togglePill() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 300)
        .glassEffect(.regular, in: Capsule())
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!meetings.pillState.controlsEnabled && symbol != "arrow.up.left.and.arrow.down.right")
        .help(help)
    }
}
