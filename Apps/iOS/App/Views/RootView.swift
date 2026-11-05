import SwiftUI

struct RootView: View {
    let controller: AppController
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { HomeView(controller: controller) }
                .tabItem { Label("Compose", systemImage: "waveform") }.tag(0)
            NavigationStack { HistoryView(controller: controller) }
                .tabItem { Label("History", systemImage: "clock") }.tag(1)
            NavigationStack { MeetingsView(controller: controller.meetings) }
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }.tag(3)
            NavigationStack { SettingsView(controller: controller) }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .tint(.indigo)
        .onChange(of: controller.meetings.openRequests) { tab = 3 }
        .onChange(of: tab) { _, selected in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            CompanionAppDelegate.isEditingSettings = selected == 2 || selected == 3
        }
    }
}
