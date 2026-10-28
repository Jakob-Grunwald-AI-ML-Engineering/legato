import AppKit
import SwiftUI

@main
struct LegatoMacApp: App {
    private let controller = MacAppController.shared

    init() {
        MacAppController.shared.bootstrap()
        #if DEBUG
        MacMeetingDiagnostics.shared?.install(meetings: MacAppController.shared.meetings)
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(controller)
        } label: {
            MenuBarLabel()
                .environment(controller)
        }
        .menuBarExtraStyle(.window)

        Window("Set up Legato", id: MacAppController.onboardingWindowID) {
            OnboardingView()
                .environment(controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Meetings", id: MeetingController.windowID) {
            MeetingsWindow()
                .environment(controller)
        }
        .defaultLaunchBehavior(.suppressed)
        .commands {
            // Control-Command-M: Command-M stays Minimize.
            CommandGroup(after: .windowArrangement) {
                Button(controller.meetings.pillVisible ? "Expand Meeting Pill" : "Shrink Meeting to Pill") {
                    controller.meetings.togglePill()
                }
                .keyboardShortcut("m", modifiers: [.control, .command])
                .disabled(controller.meetings.phase != .recording)
            }
        }

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}

/// The menu-bar icon. It is always on screen, so it also relays the controller's requests to open
/// the onboarding window (a view is the only place the `openWindow` action exists).
private struct MenuBarLabel: View {
    @Environment(MacAppController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: controller.setupAttention
            ? "exclamationmark.triangle.fill"
            : controller.isDictating ? "waveform.circle.fill" : "waveform")
            .onChange(of: controller.onboardingRequests, initial: true) { _, count in
                guard count > 0 else { return }
                NSApp.activate()
                openWindow(id: MacAppController.onboardingWindowID)
            }
            .onChange(of: controller.meetings.windowRequests) { _, count in
                guard count > 0 else { return }
                NSApp.activate()
                openWindow(id: MeetingController.windowID)
            }
    }
}
