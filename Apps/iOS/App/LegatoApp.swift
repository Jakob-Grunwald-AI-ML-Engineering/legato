import AppIntents
import SwiftUI

struct LegatoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDictationIntent(), phrases: ["Toggle \(.applicationName) dictation", "Dictate with \(.applicationName)"], shortTitle: "Toggle dictation", systemImageName: "mic.fill")
    }
}

@main
struct LegatoApp: App {
    @State private var controller = AppController.shared
    init() { LegatoShortcuts.updateAppShortcutParameters() }
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if E2E.showsKeyboardHarness { KeyboardHarness() } else { RootView(controller: controller) }
                #else
                RootView(controller: controller)
                #endif
            }.onOpenURL { url in Task { await controller.handle(url) } }
        }
    }
}
