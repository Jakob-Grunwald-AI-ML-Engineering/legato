import SwiftUI

struct HomeView: View {
    let controller: AppController
    @State private var sample = ""
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 54)).foregroundStyle(.tint)
            Text(controller.notice).font(.title2.bold())
            Text("Your keyboard is ready. Voice composition arrives with the next Composer legs.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { Task { _ = await controller.toggle() } } label: { Label("Voice composer", systemImage: "mic.fill") }
                .buttonStyle(.borderedProminent)
            TextField("Try your keyboard here", text: $sample, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Spacer()
        }.padding(28)
    }
}
