import SwiftUI
import LegatoComposerDoc
import Pow

public struct ComposerView: View {
    public let snapshot: DocumentSnapshot
    public var tail: String
    public var pendingLineIDs: Set<String>
    public var busy: Bool
    public var correctionDraft: String?
    public var correctionCountdownStart: Double?
    public var correctionCountdownDeadline: Double?
    public var onSelect: (QuoteSelection) -> Void
    public var onDeselect: () -> Void
    public var onSendCorrection: (() -> Void)?
    public var onPick: (String, String, String) -> Void
    @State private var selected: QuoteSelection?
    @State private var committedSelection: QuoteSelection?
    @State private var dragStart: QuoteSelection?
    @GestureState private var isSelecting = false
    @State private var nativeSelecting = false
    @State private var bounds: [WordBounds] = []
    @State private var viewportSize: CGSize = .zero
    @State private var reservesSpace = false
    public init(snapshot: DocumentSnapshot, tail: String = "", pendingLineIDs: Set<String> = [], busy: Bool = false,
                correctionDraft: String? = nil, correctionCountdownStart: Double? = nil, correctionCountdownDeadline: Double? = nil,
                onSelect: @escaping (QuoteSelection) -> Void = { _ in },
                onDeselect: @escaping () -> Void = {}, onSendCorrection: (() -> Void)? = nil,
                onPick: @escaping (String, String, String) -> Void = { _, _, _ in }) {
        self.snapshot = snapshot; self.tail = tail; self.pendingLineIDs = pendingLineIDs; self.busy = busy
        self.correctionDraft = correctionDraft; self.correctionCountdownStart = correctionCountdownStart; self.correctionCountdownDeadline = correctionCountdownDeadline; self.onSelect = onSelect; self.onDeselect = onDeselect
        self.onSendCorrection = onSendCorrection; self.onPick = onPick
    }
    private var preferredBubbleHeight: CGFloat { correctionDraft?.isEmpty == false ? 100 : 68 }
    private var reservedHeight: CGFloat { reservesSpace ? min(100, viewportSize.height * 0.6) : 0 }
    public var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if reservesSpace { Color.clear.frame(height: reservedHeight).allowsHitTesting(false) }
                ScrollView {
                    let content = VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(snapshot.lines.enumerated()), id: \.element.id) { index, line in
                            LineView(line: line, ordinal: index + 1, pending: pendingLineIDs.contains(line.id),
                                     selected: selected?.wordIDs(in: snapshot) ?? [])
                                .id(line.id)
                                .transition(AnyTransition.asymmetric(insertion: .opacity.combined(with: .movingParts.blur(radius: 6)), removal: .movingParts.vanish(Color.secondary)))
                        }
                        if !tail.isEmpty { Text(tail).foregroundStyle(.secondary).italic().transition(.opacity) }
                        if snapshot.lines.isEmpty && tail.isEmpty { Text("Speak to compose…").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Color.black.opacity(0.001))
                        .contentShape(Rectangle())
                        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("composerViewport")).onEnded { value in
                            guard let word = word(at: value.location) else { dismissSelection(); return }
                            select(word, commit: true)
                        })
                    #if canImport(UIKit)
                    content.background(QuoteGestureBridge(reservedHeight: reservedHeight,
                        canBegin: { word(at: $0) != nil },
                        began: { point in dragStart = word(at: point); nativeSelecting = true; moveQuote(to: point) },
                        changed: moveQuote,
                        ended: { accepted in
                            if accepted, let selected { commit(selected) } else { selected = committedSelection }
                            dragStart = nil; nativeSelecting = false
                        }))
                    #else
                    content.simultaneousGesture(quoteGesture)
                    #endif
                }.background(Color.black.opacity(0.001)).scrollDisabled(isSelecting)
            }
            .coordinateSpace(name: "composerViewport")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
            .onPreferenceChange(WordBoundsKey.self) { bounds = $0 }
            .onChange(of: committedSelection) { _, value in
                if reservesSpace, let value {
                    Task { @MainActor in await Task.yield(); proxy.scrollTo(value.lineID, anchor: .top) }
                }
            }
            .overlay { GeometryReader { geometry in
                if !isSelecting && !nativeSelecting, let selected, let selection = selectionGeometry(selected) {
                    let width = min(280, max(100, geometry.size.width - 16))
                    let topSpace = max(0, selection.extent.minY - 12)
                    let bottomSpace = max(0, geometry.size.height - selection.extent.maxY - 12)
                    let above = topSpace >= preferredBubbleHeight || topSpace >= bottomSpace
                    let anchor = above ? selection.first : selection.last
                    let available = above ? topSpace : bottomSpace
                    let height = min(available, preferredBubbleHeight)
                    let x = min(max(anchor.midX, width / 2 + 8), geometry.size.width - width / 2 - 8)
                    if available >= 30 {
                        AlternativesPopover(capturedText: correctionDraft ?? "",
                            pointX: min(width - 4, max(4, anchor.midX - x + width / 2)), pointsDown: above,
                            maximumHeight: available, countdownStart: correctionCountdownStart, countdownDeadline: correctionCountdownDeadline, dismiss: dismissSelection, send: onSendCorrection)
                            .frame(width: width)
                            .position(x: x, y: above ? selection.extent.minY - height / 2 - 10 : selection.extent.maxY + height / 2 + 10)
                            .transition(AnyTransition.scale(scale: 0.92, anchor: above ? .bottom : .top).combined(with: .opacity).combined(with: .movingParts.blur(radius: 4)))
                            .accessibilityIdentifier("composer-correction-popover")
                    }
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
            .onChange(of: correctionDraft) { old, next in if old != nil && next == nil { dismissSelection() } }
            .onChange(of: snapshot) { _, next in if let selected, selected.resolved(in: next) == nil { dismissSelection() } }
        }
    }
    private var quoteGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("composerViewport")))
            .updating($isSelecting) { value, active, _ in if case .second(true, _) = value { active = true } }
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    if dragStart == nil { dragStart = word(at: drag.startLocation) }
                    moveQuote(to: drag.location)
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value, word(at: drag.startLocation) != nil, let selected { commit(selected) }
                dragStart = nil
            }
    }
    private func moveQuote(to point: CGPoint) {
        guard let start = dragStart, let end = word(at: point, nearest: true) else { return }
        select(.init(lineID: start.lineID, wordID: start.wordID, endLineID: end.lineID, endWordID: end.wordID), commit: false)
    }
    private func dismissSelection() {
        guard selected != nil else { return }
        selected = nil; committedSelection = nil; dragStart = nil; reservesSpace = false; onDeselect()
    }
    private func commit(_ selection: QuoteSelection) {
        if let rect = selectionGeometry(selection)?.extent,
           max(rect.minY - 12, viewportSize.height - rect.maxY - 12) < preferredBubbleHeight { reservesSpace = true }
        committedSelection = selection; onSelect(selection)
    }
    private func select(_ value: QuoteSelection, commit: Bool) {
        guard let normalized = value.resolved(in: snapshot) else { return }
        selected = normalized
        if commit { self.commit(normalized) }
    }
    private func word(at point: CGPoint, nearest: Bool = false) -> QuoteSelection? {
        if let hit = bounds.first(where: { $0.rects.contains { $0.insetBy(dx: -3, dy: -4).contains(point) } }) { return .init(lineID: hit.lineID, wordID: hit.wordID) }
        guard nearest, let hit = bounds.min(by: { distance($0, point) < distance($1, point) }) else { return nil }
        return .init(lineID: hit.lineID, wordID: hit.wordID)
    }
    private func distance(_ value: WordBounds, _ p: CGPoint) -> CGFloat { value.rects.map { hypot(max($0.minX - p.x, 0, p.x - $0.maxX), max($0.minY - p.y, 0, p.y - $0.maxY)) }.min() ?? .infinity }
    private func selectionGeometry(_ selection: QuoteSelection) -> (extent: CGRect, first: CGRect, last: CGRect)? {
        let ids = selection.wordIDs(in: snapshot)
        let visible = CGRect(x: 0, y: reservedHeight, width: viewportSize.width, height: max(0, viewportSize.height - reservedHeight))
        let rects = bounds.filter { ids.contains($0.wordID) }.flatMap(\.rects).map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
        guard let extent = rects.reduce(nil as CGRect?, { $0?.union($1) ?? $1 }),
              let top = rects.map(\.minY).min(), let bottom = rects.map(\.maxY).max() else { return nil }
        let first = rects.filter { abs($0.minY - top) < 4 }.reduce(CGRect.null) { $0.union($1) }
        let last = rects.filter { abs($0.maxY - bottom) < 4 }.reduce(CGRect.null) { $0.union($1) }
        return (extent, first, last)
    }
}
