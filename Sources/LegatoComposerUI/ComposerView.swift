import SwiftUI
import LegatoComposerDoc
import Pow

public struct ComposerView: View {
    public let snapshot: DocumentSnapshot
    public var tail: String
    public var pendingLineIDs: Set<String>
    public var busy: Bool
    public var onSelect: (QuoteSelection) -> Void
    public var onDeselect: () -> Void
    public var onPick: (String, String, String) -> Void
    @State private var selected: QuoteSelection?
    @State private var committedSelection: QuoteSelection?
    @State private var dragStart: QuoteSelection?
    @GestureState private var isSelecting = false
    @State private var bounds: [WordBounds] = []
    @State private var bubbleSize = CGSize(width: 260, height: 92)
    public init(snapshot: DocumentSnapshot, tail: String = "", pendingLineIDs: Set<String> = [], busy: Bool = false,
                onSelect: @escaping (QuoteSelection) -> Void = { _ in },
                onDeselect: @escaping () -> Void = {},
                onPick: @escaping (String, String, String) -> Void = { _, _, _ in }) {
        self.snapshot = snapshot; self.tail = tail; self.pendingLineIDs = pendingLineIDs; self.busy = busy
        self.onSelect = onSelect; self.onDeselect = onDeselect; self.onPick = onPick
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(snapshot.lines.enumerated()), id: \.element.id) { index, line in
                    LineView(line: line, ordinal: index + 1, pending: pendingLineIDs.contains(line.id),
                             selected: selected?.wordIDs(in: snapshot) ?? [])
                        .id(line.id)
                        .transition(AnyTransition.asymmetric(insertion: .opacity.combined(with: .movingParts.blur(radius: 6)), removal: .movingParts.vanish(Color.secondary)))
                }
                if !tail.isEmpty { Text(tail).foregroundStyle(.secondary).italic().transition(.opacity) }
                if snapshot.lines.isEmpty && tail.isEmpty { Text("Speak to compose…").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
                .contentShape(Rectangle())
                .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("composerViewport")).onEnded { value in
                    guard let word = word(at: value.location) else { dismissSelection(); return }
                    select(word, commit: true)
                })
                .highPriorityGesture(quoteGesture)
        }
        .coordinateSpace(name: "composerViewport")
        .onPreferenceChange(WordBoundsKey.self) { bounds = $0 }
        .overlay { GeometryReader { geometry in
            if let selected, let rect = selectedRect(selected), rect.intersects(CGRect(origin: .zero, size: geometry.size)) {
                let width = min(280, max(100, geometry.size.width - 16))
                let x = min(max(rect.midX, width / 2 + 8), geometry.size.width - width / 2 - 8)
                let above = rect.minY >= bubbleSize.height + 12
                let y = above ? rect.minY - bubbleSize.height / 2 - 10 : min(geometry.size.height - bubbleSize.height / 2 - 4, rect.maxY + bubbleSize.height / 2 + 10)
                AlternativesPopover(quote: selected.quote(in: snapshot), word: selected.isSingleWord ? selectedWord(selected) : nil,
                                    pointX: min(width - 4, max(4, rect.midX - x + width / 2)), pointsDown: above,
                                    dismiss: dismissSelection) { text in
                    onPick(selected.lineID, selected.wordID, text); dismissSelection()
                }
                .frame(width: width)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
                .position(x: x, y: max(bubbleSize.height / 2 + 4, y))
                .transition(AnyTransition.scale(scale: 0.92, anchor: above ? .bottom : .top).combined(with: .opacity).combined(with: .movingParts.blur(radius: 4)))
                .accessibilityIdentifier("composer-correction-popover")
            }
        } }
        .overlay(alignment: .topTrailing) { if busy { AgentStatusGlyph().padding(8).allowsHitTesting(false) } }
        .animation(.smooth(duration: 0.3), value: snapshot)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selected)
        .onChange(of: isSelecting) { _, active in
            if !active {
                Task { @MainActor in
                    await Task.yield()
                    if !isSelecting, dragStart != nil { selected = committedSelection; dragStart = nil }
                }
            }
        }
        .onChange(of: snapshot) { _, next in
            if let selected, selected.resolved(in: next) == nil { dismissSelection() }
        }
    }
    private var quoteGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("composerViewport")))
            .updating($isSelecting) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    if dragStart == nil { dragStart = word(at: drag.startLocation) }
                    guard let start = dragStart, let end = word(at: drag.location, nearest: true) else { return }
                    select(QuoteSelection(lineID: start.lineID, wordID: start.wordID, endLineID: end.lineID, endWordID: end.wordID), commit: false)
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value, word(at: drag.startLocation) != nil, let selected {
                    committedSelection = selected; onSelect(selected)
                }
                dragStart = nil
            }
    }
    private func dismissSelection() {
        guard selected != nil else { return }
        selected = nil; committedSelection = nil; dragStart = nil; onDeselect()
    }
    private func select(_ value: QuoteSelection, commit: Bool) {
        guard let normalized = value.resolved(in: snapshot) else { return }
        selected = normalized
        if commit { committedSelection = normalized; onSelect(normalized) }
    }
    private func word(at point: CGPoint, nearest: Bool = false) -> QuoteSelection? {
        if let hit = bounds.first(where: { $0.rects.contains { $0.insetBy(dx: -3, dy: -4).contains(point) } }) { return .init(lineID: hit.lineID, wordID: hit.wordID) }
        guard nearest, let hit = bounds.min(by: { distance($0, point) < distance($1, point) }) else { return nil }
        return .init(lineID: hit.lineID, wordID: hit.wordID)
    }
    private func distance(_ value: WordBounds, _ p: CGPoint) -> CGFloat { value.rects.map { hypot(max($0.minX - p.x, 0, p.x - $0.maxX), max($0.minY - p.y, 0, p.y - $0.maxY)) }.min() ?? .infinity }
    private func selectedRect(_ selection: QuoteSelection) -> CGRect? {
        let ids = selection.wordIDs(in: snapshot)
        let rects = bounds.filter { ids.contains($0.wordID) }.flatMap(\.rects)
        guard let top = rects.map(\.minY).min() else { return nil }
        // Point to actual selected glyphs on the first visual row, never the empty centre of a wrapped quote.
        return rects.filter { abs($0.minY - top) < 4 }.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
    }
    private func selectedWord(_ selection: QuoteSelection) -> Word? { snapshot.lines.first { $0.id == selection.lineID }?.words.first { $0.id == selection.wordID } }
}
