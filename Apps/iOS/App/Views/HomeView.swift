import SwiftUI

/// The in-app fallback for dictation: a big button, the state, and the last transcript.
struct HomeView: View {
    let controller: AppController

    var body: some View {
        VStack(spacing: 24) {
            Button {
                Task { _ = await controller.toggle() }
            } label: {
                Image(systemName: controller.isDictating ? "stop.fill" : "mic.fill")
                    .font(.system(size: 56))
                    .frame(width: 160, height: 160)
                    .foregroundStyle(.white)
                    .background(controller.isDictating ? Color.red : Color.accentColor, in: Circle())
            }
            .accessibilityLabel(controller.isDictating ? "Stop dictation" : "Start dictation")

            Text(controller.isDictating ? "Listening" : "Ready")
                .font(.title2.bold())

            if let text = controller.lastTranscript {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Last transcript").font(.headline)
                    ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("Copy") { controller.copy(text) }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Legato")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                NavigationLink("History") { HistoryView(controller: controller) }
                Spacer()
                NavigationLink("Settings") { SettingsView(controller: controller) }
            }
        }
    }
}
