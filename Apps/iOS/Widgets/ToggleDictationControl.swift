import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen control: the same toggle as the Action Button.
struct ToggleDictationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.gruenwald.legato.toggle-dictation") {
            ControlWidgetButton(action: ToggleDictationIntent()) {
                Label("Record", systemImage: "mic.fill")
            }
        }
        .displayName("Legato recording")
        .description("Uses the Meeting or Dictation action chosen in Legato Settings.")
    }
}
