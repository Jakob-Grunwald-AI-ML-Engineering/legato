import AppIntents
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
