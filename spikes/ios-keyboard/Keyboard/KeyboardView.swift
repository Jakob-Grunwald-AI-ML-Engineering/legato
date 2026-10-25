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
                    // Path A, the critical test: an AppIntent button inside the keyboard extension.
                    Button(intent: ToggleDictationIntent(source: "keyboard")) {
                        label(model.dictState == "listening" ? "Stop dictating" : "Dictate", tint: .blue)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        model.log("A: tapped Button(intent: ToggleDictationIntent) dictState=\(model.dictState)")
                    })
                    .gridCellColumns(2)
                    Button { model.toggleViaDarwin() } label: { label("Fallback: Darwin") }
                }
                GridRow {
                    Button { model.insertTestString() } label: { label("Insert test") }
                        .gridCellColumns(3)
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
