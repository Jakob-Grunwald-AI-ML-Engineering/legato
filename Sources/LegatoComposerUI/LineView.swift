import SwiftUI
import LegatoComposerDoc

struct LineView: View {
    var line: Line
    var ordinal: Int
    var pending: Bool
    @State private var progress = 1.0
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if line.kind == .li { Text("•") }
            if line.kind == .oli { Text("\(ordinal).") }
            if line.kind == .quote { Rectangle().fill(.secondary).frame(width: 3) }
            Text(attributed)
                .font(line.kind == .h1 ? .title2.bold() : line.kind == .h2 || line.kind == .h3 ? .headline : .body)
                .textRenderer(WordFX(progress: progress, pending: pending))
                .onChange(of: line.version) { _, _ in
                    progress = 0
                    withAnimation(.easeOut(duration: 0.35)) { progress = 1 }
                }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var attributed: AttributedString {
        var result = AttributedString()
        for (index, word) in line.words.enumerated() {
            var part = AttributedString((index == 0 ? "" : " ") + word.text)
            part.link = URL(string: "legato-word://" + word.id)
            part.foregroundColor = ConfidenceTint.color(word.confidence)
            if word.pinned { part.underlineStyle = .single }
            result += part
        }
        return result
    }
}
