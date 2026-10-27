import SwiftUI
import WidgetKit

@main
struct LegatoWidgets: WidgetBundle {
    var body: some Widget {
        DictationLiveActivity()
        MeetingLiveActivity()
        ToggleDictationControl()
    }
}
