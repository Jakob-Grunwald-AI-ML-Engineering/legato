import SwiftUI
import LegatoComposerDoc

struct LineView: View {
    var line: Line
    var ordinal: Int
    var pending: Bool
    var selected: Set<String>
    var animateInsertion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edit = WordEditPresentation(old: [], new: [])
    @State private var progress = 1.0
    @State private var appeared = false
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
                .onAppear {
                    if animateInsertion && !appeared { animate(old: [], new: line.words) }
                    appeared = true
                }
                .onChange(of: line.words) { old, new in animate(old: old, new: new) }
                .onChange(of: reduceMotion) { _, enabled in if enabled { progress = 1 } }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func animate(old: [Word], new: [Word]) {
        // A newer update replaces this plan immediately; no delayed per-word work survives it.
        edit = WordEditPresentation(old: old, new: new)
        guard !reduceMotion, !edit.isEmpty else { progress = 1; return }
        progress = 0
        withAnimation(.linear(duration: WordEditPresentation.duration)) { progress = 1 }
    }
    private var renderer: WordFX {
        var renderer = WordFX(progress: progress, pending: pending)
        renderer.selected = selected
        renderer.edit = edit
        renderer.reduceMotion = reduceMotion
        renderer.measure = { bounds in
            Task { @MainActor in
                if measured != bounds { measured = bounds }
            }
        }
        return renderer
    }
    private var text: Text {
        // A left-fold builds a deeply nested Text concatenation for long paragraphs.
        // Pairwise composition keeps the view tree logarithmic in the word count.
        var pieces = line.words.enumerated().map { index, word in
            var value = AttributedString(word.text)
            value.foregroundColor = ConfidenceTint.color(word.confidence)
            if word.pinned { value.underlineStyle = .single }
            return Text(index == 0 ? "" : " ") + Text(value).customAttribute(ComposerWordAttribute(id: word.id))
        }
        while pieces.count > 1 {
            pieces = stride(from: 0, to: pieces.count, by: 2).map { index in
                index + 1 < pieces.count ? pieces[index] + pieces[index + 1] : pieces[index]
            }
        }
        return pieces.first ?? Text("")
    }
}
struct WordBounds: Equatable, Sendable { var lineID: String; var wordID: String; var rects: [CGRect] }
struct WordBoundsKey: PreferenceKey {
    static let defaultValue: [WordBounds] = []
    static func reduce(value: inout [WordBounds], nextValue: () -> [WordBounds]) { value += nextValue() }
}
