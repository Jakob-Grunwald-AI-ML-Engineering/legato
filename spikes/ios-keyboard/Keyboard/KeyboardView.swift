import AppIntents
import SwiftUI

struct KeyboardView: View {
    let model: KeyboardModel
    let next: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle().fill(model.alive ? .green : .red).frame(width: 12, height: 12)
                Text(model.alive ? "session ALIVE" : "session DEAD")
                Text("age \(model.age < 0 ? "-" : String(format: "%.1fs", model.age))")
                    .monospacedDigit()
                ProgressView(value: Double(model.level)).frame(width: 60)
                Spacer()
                Text(model.dictState).font(.caption)
            }
            .font(.footnote)

            Text(model.lastEvent).font(.caption2).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    // Path (a): AppIntent button inside the keyboard.
                    Button(intent: StartSessionIntent()) { label("A: Button(intent:)") }
                        .simultaneousGesture(TapGesture().onEnded { model.log("A: tapped Button(intent:)") })
                    Button { model.startViaDarwin() } label: { label("B: Darwin note") }
                    Button { model.startViaURL() } label: { label("C: URL (hop)") }
                }
                GridRow {
                    Button { model.toggleDictation() } label: {
                        label(model.dictState == "listening" ? "Stop dictating" : "Dictate", tint: .blue)
                    }
                    .gridCellColumns(2)
                    Button { model.insertTestString() } label: { label("Insert test") }
                }
            }
            .buttonStyle(.plain)

            HStack {
                Button(action: next) { Image(systemName: "globe") }
                Spacer()
            }
        }
        .padding(10)
        .background(Color(uiColor: .systemGray5))
    }

    private func label(_ text: String, tint: Color = .gray) -> some View {
        Text(text).font(.footnote.bold()).frame(maxWidth: .infinity, minHeight: 44)
            .background(tint.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
