import AppIntents
import SwiftUI
import Synchronization

struct LegatoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDictationIntent(), phrases: ["Toggle \(.applicationName) dictation", "Dictate with \(.applicationName)"], shortTitle: "Toggle recording", systemImageName: "mic.fill")
    }
}

@main
struct LegatoApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @State private var controller = AppController.shared
    @Environment(\.scenePhase) private var scenePhase
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
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Task { await controller.prepareForBackground() } }
                }
        }
    }
}

/// Settings and meeting metadata need ordinary text entry even when the voice-only Legato keyboard was last selected.
/// UIKit may ask from a background thread (`UIKeyboardInputModeController`), so the answer is nonisolated and the flag is locked (#252).
@MainActor final class CompanionAppDelegate: NSObject, UIApplicationDelegate {
    private nonisolated static let editingSettings = Mutex(false)
    nonisolated static var isEditingSettings: Bool {
        get { editingSettings.withLock { $0 } }
        set { editingSettings.withLock { $0 = newValue } }
    }
    nonisolated func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard || !Self.isEditingSettings
    }
}
