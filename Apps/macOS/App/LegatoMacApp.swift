import AppKit
import SwiftUI

@main
struct LegatoMacApp: App {
    private let controller = MacAppController.shared
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    init() {
        MacAppController.shared.bootstrap()

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

        Window("Meetings", id: MeetingController.windowID) {
            MeetingsWindow()
                .environment(controller)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 720)
        .defaultLaunchBehavior(.suppressed)

        Window("Set up Legato", id: MacAppController.onboardingWindowID) {
            OnboardingView()
                .environment(controller)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(controller)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 640)
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
            : controller.meetings.isRecording ? "record.circle.fill"
            : controller.isDictating || controller.dictation.isActive ? "waveform.circle.fill" : "waveform")
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

/// Opening Legato again (Spotlight, Finder, `open`) shows the Meetings window, so the app can be reached when its menu-bar
/// icon is hidden behind the notch. The reopen that comes with the launch itself is ignored: a first launch shows the
/// onboarding or nothing, not a window.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private let launched = ProcessInfo.processInfo.systemUptime
    static let launchGrace: TimeInterval = 2

    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ProcessInfo.processInfo.systemUptime - launched > Self.launchGrace { MacAppController.shared.meetings.showWindow() }
        return false
    }
}
