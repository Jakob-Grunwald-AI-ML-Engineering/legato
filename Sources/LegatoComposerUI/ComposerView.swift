import SwiftUI
import LegatoComposerDoc
import Pow

public struct ComposerView: View {
    public let snapshot: DocumentSnapshot
    public var tail: String
    public var pendingLineIDs: Set<String>
    public var busy: Bool
    public var onWordTap: (String, String) -> Void
    public var onPick: (String, String, String) -> Void
    @State private var selected: SelectedWord?
    public init(snapshot: DocumentSnapshot, tail: String = "", pendingLineIDs: Set<String> = [], busy: Bool = false,
                onWordTap: @escaping (String, String) -> Void = { _, _ in },
                onPick: @escaping (String, String, String) -> Void = { _, _, _ in }) {
        self.snapshot = snapshot; self.tail = tail; self.pendingLineIDs = pendingLineIDs; self.busy = busy
        self.onWordTap = onWordTap; self.onPick = onPick
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(snapshot.lines.enumerated()), id: \.element.id) { index, line in
                    LineView(line: line, ordinal: index + 1, pending: pendingLineIDs.contains(line.id))
                        .transition(.asymmetric(insertion: .opacity.combined(with: .blurReplace), removal: .movingParts.vanish(Color.secondary)))
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "legato-word", let word = line.words.first(where: { $0.id == url.host }) else { return .systemAction }
                            onWordTap(line.id, word.id); selected = .init(lineID: line.id, word: word); return .handled
                        })
                }
                if !tail.isEmpty { Text(tail).foregroundStyle(.secondary).italic().transition(.opacity) }
                if snapshot.lines.isEmpty && tail.isEmpty { Text("Speak to compose…").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .overlay(alignment: .topTrailing) { if busy { AgentStatusGlyph().padding(8) } }
        .animation(.smooth(duration: 0.3), value: snapshot)
        .popover(item: $selected) { selection in
            AlternativesPopover(word: selection.word) { text in onPick(selection.lineID, selection.word.id, text); selected = nil }
                .presentationCompactAdaptation(.popover)
        }
    }
}
private struct SelectedWord: Identifiable { var lineID: String; var word: Word; var id: String { word.id } }
