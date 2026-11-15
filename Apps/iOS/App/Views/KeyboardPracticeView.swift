import SwiftUI

struct KeyboardPracticeView: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        Form {
            Section {
                TextField("Write something here…", text: $text, axis: .vertical)
                    .lineLimit(6...16).focused($focused)
                    .accessibilityIdentifier("home.keyboardPractice")
            } footer: { Text("Touch and hold the globe key and choose Legato. This text stays in this practice screen.") }
        }
        .onAppear { CompanionAppDelegate.isEditingSettings = false }
        .onDisappear { CompanionAppDelegate.isEditingSettings = true }
        .navigationTitle("Try your keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focused = false } } }
    }
}
