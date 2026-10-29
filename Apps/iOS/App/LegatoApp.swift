import AppIntents
import BackgroundTasks
import SwiftUI

/// Binds the intent to the Action Button ("Toggle Legato dictation" in Settings > Action Button).
struct LegatoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: ["Toggle \(.applicationName) dictation", "Dictate with \(.applicationName)"],
            shortTitle: "Toggle dictation",
            systemImageName: "mic.fill")
    }
}

@main
struct LegatoApp: App {
    @State private var controller = AppController.shared

    init() {
        // `controller` is built with the App, so the coordinator exists on every launch, including
        // background launches from the intent.
        LegatoShortcuts.updateAppShortcutParameters()
        // Finishes a meeting's heavy steps in a window iOS grants after the app was suspended. It must be
        // registered before the launch ends.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: MeetingBackgroundTask.identifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            nonisolated(unsafe) let box = task
            Task { @MainActor in AppController.shared.meetings.handleBackgroundProcessing(box) }
        }
        #if LEGATO_INTERNAL
        SessionProbe.runIfRequested(models: AppController.shared.models)  // `-LegatoSessionProbe <mode>`
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if E2E.showsKeyboardHarness {
            KeyboardHarness()
        } else {
            RootView(controller: controller)
        }
        #else
        RootView(controller: controller)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            content
                .onOpenURL { url in Task { await controller.handle(url) } }
        }
    }
}
