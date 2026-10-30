import SwiftUI
import LegatoComposerDoc

struct LineView: View {
    var line: Line
    var ordinal: Int
    var pending: Bool
    var selected: Set<String>
    @State private var progress = 1.0
    @State private var measured: [String: [CGRect]] = [:]
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if line.kind == .li { Text("•") }
            if line.kind == .oli { Text("\(ordinal).") }
            if line.kind == .quote { Rectangle().fill(.secondary).frame(width: 3) }
            text
                .font(line.kind == .h1 ? .title2.bold() : line.kind == .h2 || line.kind == .h3 ? .headline : .body)
                .textRenderer(renderer)
                .background { GeometryReader { geometry in
                    Color.clear.preference(key: WordBoundsKey.self, value: measured.map { id, rects in
                        WordBounds(lineID: line.id, wordID: id, rects: rects.map { $0.offsetBy(dx: geometry.frame(in: .named("composerViewport")).minX, dy: geometry.frame(in: .named("composerViewport")).minY) })
                    })
                } }
                .onChange(of: line.version) { _, _ in
                    progress = 0
                    withAnimation(.easeOut(duration: 0.42)) { progress = 1 }
                }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var renderer: WordFX {
        var renderer = WordFX(progress: progress, pending: pending)
        renderer.selected = selected
        renderer.measure = { bounds in
            Task { @MainActor in
                if measured != bounds { measured = bounds }
            }
        }
        return renderer
    }
    private var text: Text {
        line.words.enumerated().reduce(Text("")) { result, item in
            let (index, word) = item
            var value = AttributedString(word.text)
            value.foregroundColor = ConfidenceTint.color(word.confidence)
            if word.pinned { value.underlineStyle = .single }
            return result + Text(index == 0 ? "" : " ") + Text(value).customAttribute(ComposerWordAttribute(id: word.id))
        }
    }
}
struct WordBounds: Equatable, Sendable { var lineID: String; var wordID: String; var rects: [CGRect] }
struct WordBoundsKey: PreferenceKey {
    static let defaultValue: [WordBounds] = []
    static func reduce(value: inout [WordBounds], nextValue: () -> [WordBounds]) { value += nextValue() }
}
