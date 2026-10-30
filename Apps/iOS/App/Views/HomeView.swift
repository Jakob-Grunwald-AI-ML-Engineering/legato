import SwiftUI
import LegatoComposerUI
import LegatoAgent
struct HomeView: View {
    let controller: AppController
    @State private var sample = ""
    var body: some View {
        VStack(spacing: 12) {
            ComposerView(snapshot: controller.composer.snapshot, tail: controller.composer.tail,
                         pendingLineIDs: controller.composer.pendingLineIDs, busy: controller.composer.busy,
                         onWordTap: { line, word in Task { await controller.composer.tap(lineID: line, wordID: word) } },
                         onPick: { line, word, text in Task { await controller.composer.pick(lineID: line, wordID: word, text: text) } })
            Text(controller.notice).font(.caption).foregroundStyle(controller.composer.error == nil ? Color.secondary : .red)
            HStack {
                ModeChip(mode: controller.composer.mode.rawValue) { value in Task { if let mode = ComposerMode(rawValue: value) { await controller.composer.setMode(mode) } } }
                Button { Task { _ = await controller.toggle() } } label: { Label(controller.isDictating ? "Stop" : "Compose", systemImage: controller.isDictating ? "stop.fill" : "mic.fill") }.buttonStyle(.borderedProminent)
                Button("Copy") { controller.copy(controller.composer.renderedText) }
                Button("Cancel") { Task { await controller.composer.cancel() } }
            }
            TextField("Try your keyboard here", text: $sample, axis: .vertical).textFieldStyle(.roundedBorder)
        }.padding()
    }
}
