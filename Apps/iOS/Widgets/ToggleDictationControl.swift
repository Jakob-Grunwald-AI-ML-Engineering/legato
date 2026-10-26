import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen control: the same toggle as the Action Button.
struct ToggleDictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.gruenwald.legato.toggle-dictation") {
            ControlWidgetButton(action: ToggleDictationIntent()) {
                Label("Dictate", systemImage: "mic.fill")
            }
        }
        .displayName("Legato dictation")
        .description("Starts dictation, or stops it when already running.")
    }
}
