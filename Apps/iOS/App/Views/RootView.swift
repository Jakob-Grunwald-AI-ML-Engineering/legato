import SwiftUI

struct RootView: View {
    let controller: AppController
    var body: some View {
        NavigationStack {
            HomeView(controller: controller)
                .navigationTitle("Legato")
                .toolbar {
                    NavigationLink { HistoryView(controller: controller) } label: { Image(systemName: "clock") }
                    NavigationLink { SettingsView(controller: controller) } label: { Image(systemName: "gearshape") }
                }
        }
    }
}
