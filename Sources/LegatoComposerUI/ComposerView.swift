import SwiftUI
import LegatoComposerDoc
import Pow

public struct ComposerView: View {
    public let snapshot: DocumentSnapshot
    public var tail: String
    public var dictationRevision: Int
    public var successfulInsertionID: String?
    public var pendingLineIDs: Set<String>
    public var busy: Bool
    public var instructionText: String
    public var instructionStatus: String
    public var instructionInputActive: Bool
    public var correctionDraft: String?
    public var correctionSubmitting: Bool
    public var correctionCountdownStart: Double?
    public var correctionCountdownDeadline: Double?
    public var onSelect: (QuoteSelection) -> Void
    public var onDeselect: () -> Void
    public var onSendCorrection: (() -> Void)?
    public var onSendInstruction: (() -> Void)?
    public var onDiscardInstruction: () -> Void
    public var onPick: (String, String, String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sendFlight = SendFlightPresentation()
    @State private var sendFlightProgress = 0.0
    @State private var presentedParagraphs: [PresentedParagraph] = []
    @State private var presentedRevision = -1
    @State private var hasPresented = false
    @State private var showsInstructionComment = false
    @State private var selected: QuoteSelection?
    @State private var committedSelection: QuoteSelection?
    @State private var dragStart: QuoteSelection?
    @GestureState private var isSelecting = false
    @State private var nativeSelecting = false
    @State private var bounds: [WordBounds] = []
    @State private var viewportSize: CGSize = .zero
    @State private var reservesSpace = false
    public init(snapshot: DocumentSnapshot, tail: String = "", dictationRevision: Int = 0, successfulInsertionID: String? = nil, pendingLineIDs: Set<String> = [], busy: Bool = false,
                instructionText: String = "", instructionStatus: String = "Ready", instructionInputActive: Bool = false,
                correctionDraft: String? = nil, correctionSubmitting: Bool = false, correctionCountdownStart: Double? = nil, correctionCountdownDeadline: Double? = nil,
                onSelect: @escaping (QuoteSelection) -> Void = { _ in },
                onDeselect: @escaping () -> Void = {}, onSendCorrection: (() -> Void)? = nil,
                onSendInstruction: (() -> Void)? = nil, onDiscardInstruction: @escaping () -> Void = {},
                onPick: @escaping (String, String, String) -> Void = { _, _, _ in }) {
        self.snapshot = snapshot; self.tail = tail; self.dictationRevision = dictationRevision; self.successfulInsertionID = successfulInsertionID; self.pendingLineIDs = pendingLineIDs; self.busy = busy
        self.instructionText = instructionText; self.instructionStatus = instructionStatus; self.instructionInputActive = instructionInputActive
        self.correctionDraft = correctionDraft; self.correctionSubmitting = correctionSubmitting; self.correctionCountdownStart = correctionCountdownStart; self.correctionCountdownDeadline = correctionCountdownDeadline; self.onSelect = onSelect; self.onDeselect = onDeselect
        self.onSendCorrection = onSendCorrection; self.onSendInstruction = onSendInstruction; self.onDiscardInstruction = onDiscardInstruction; self.onPick = onPick
    }
    private var preferredBubbleHeight: CGFloat { correctionDraft?.isEmpty == false ? 96 : 54 }
    private var showsGlobalComment: Bool { showsInstructionComment && selected == nil }
    private var instructionBubbleHeight: CGFloat { instructionText.isEmpty || instructionStatus == "Done" ? 54 : 96 }
    private var reservedHeight: CGFloat {
        // Keep at least one readable draft line, but never shrink the comment to its header alone.
        let available = max(0, viewportSize.height - 44)
        if showsGlobalComment { return min(instructionBubbleHeight + 8, available) }
        return reservesSpace ? min(preferredBubbleHeight + 12, available) : 0
    }
    // Large snapshots skip implicit whole-layout animation. Local changed-word effects
    // remain independently bounded in the text renderer.
    private var animatesDraftChanges: Bool {
        var words = 0
        for line in snapshot.lines {
            words += line.words.count
            if words > 240 { return false }
        }
        return snapshot.lines.count <= 24
    }
    private func followDictation(using proxy: ScrollViewProxy) {
        guard selected == nil, !isSelecting, !nativeSelecting, !instructionInputActive else { return }
        Task { @MainActor in
            await Task.yield()
            guard selected == nil, !isSelecting, !nativeSelecting, !instructionInputActive else { return }
            // Only speech progress requests this scroll. An agent rewrite does not pull the
            // reader away from another paragraph, and an active quote keeps its anchor.
            withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("composer-dictation-tail", anchor: .bottom) }
        }
    }
    private var hasCanonicalDraft: Bool { !snapshot.lines.isEmpty || !tail.isEmpty }
    private func beginSendFlightIfNeeded() {
        if sendFlight.observe(acknowledgement: successfulInsertionID, hasDraft: hasCanonicalDraft, hadDraft: !presentedParagraphs.isEmpty) {
            var transaction = SwiftUI.Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { sendFlightProgress = 0 }
        }
    }
    public var body: some View {
        let holdsSentViewport = sendFlight.retainsViewport(acknowledgement: successfulInsertionID,
            hasDraft: hasCanonicalDraft, hadDraft: !presentedParagraphs.isEmpty)
        let previous = snapshot.revision < presentedRevision ? [] : presentedParagraphs
        // Reuse the existing lazy viewport; do not create a second tree or rasterize a long draft.
        let paragraphs = holdsSentViewport ? presentedParagraphs : ParagraphPresentation.reconcile(previous: previous, lines: snapshot.lines, animateInsertions: hasPresented)
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if reservesSpace || showsGlobalComment { Color.clear.frame(height: reservedHeight).allowsHitTesting(false) }
                ScrollView {
                    let selectedWords = selected?.wordIDs(in: snapshot) ?? []
                    let content = LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(paragraphs) { paragraph in
                            LineView(line: paragraph.line, ordinal: paragraph.ordinal, pending: pendingLineIDs.contains(paragraph.line.id),
                                     selected: selectedWords, animateInsertion: paragraph.animateInsertion)
                                .id(paragraph.id)
                                .transition(.opacity)
                        }
                        if !tail.isEmpty { Text(tail).foregroundStyle(.secondary).italic().transition(.opacity) }
                        if snapshot.lines.isEmpty && tail.isEmpty && !holdsSentViewport { Text("Speak to compose…").foregroundStyle(.secondary) }
                        Color.clear.frame(height: 1).id("composer-dictation-tail")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Color.black.opacity(0.001))
                        .contentShape(Rectangle())
                        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("composerViewport")).onEnded { value in
                            let hit = word(at: value.location)
                            #if DEBUG || LEGATO_INTERNAL
                            NSLog("composer.hit x=%.1f y=%.1f rects=%ld hit=%d", Double(value.location.x), Double(value.location.y), bounds.reduce(0) { $0 + $1.rects.count }, hit == nil ? 0 : 1)
                            #endif
                            guard let hit else { dismissSelection(); return }
                            select(hit, commit: true)
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
                }.background(Color.black.opacity(0.001)).scrollDisabled(isSelecting || holdsSentViewport)
                    .allowsHitTesting(!holdsSentViewport)
                    .offset(y: holdsSentViewport && !reduceMotion ? -min(120, max(48, viewportSize.height * 0.6)) * sendFlightProgress : 0)
                    .opacity(holdsSentViewport ? 1 - sendFlightProgress : 1)
            }
            .clipped()
            .coordinateSpace(name: "composerViewport")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
            .onPreferenceChange(WordBoundsKey.self) { bounds = $0 }
            .onAppear {
                // A Mac focus handoff can hide/reveal the same host view. Do not consume
                // its new delivery acknowledgement as though this were a fresh mount.
                guard !hasPresented else { return }
                sendFlight.reset(acknowledgement: successfulInsertionID)
                presentedParagraphs = paragraphs; presentedRevision = snapshot.revision; hasPresented = true
            }
            .onChange(of: successfulInsertionID) { _, _ in beginSendFlightIfNeeded() }
            .onChange(of: snapshot) { _, next in
                beginSendFlightIfNeeded()
                if !holdsSentViewport { presentedParagraphs = paragraphs; presentedRevision = next.revision }
            }
            .task(id: sendFlight.activeAcknowledgement) {
                guard let acknowledgement = sendFlight.activeAcknowledgement else { return }
                let duration = reduceMotion ? 0.12 : 0.36
                withAnimation(.easeIn(duration: duration)) { sendFlightProgress = 1 }
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                guard !Task.isCancelled else { return }
                var transaction = SwiftUI.Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    sendFlight.finish(acknowledgement)
                    sendFlightProgress = 0
                    if !hasCanonicalDraft { presentedParagraphs = []; presentedRevision = snapshot.revision }
                }
            }
            .onChange(of: tail) { _, next in
                if !next.isEmpty {
                    sendFlight.reset(acknowledgement: successfulInsertionID)
                    followDictation(using: proxy)
                }
            }
            .onChange(of: dictationRevision) { _, _ in followDictation(using: proxy) }
            .onChange(of: committedSelection) { _, value in
                if reservesSpace, let value {
                    Task { @MainActor in await Task.yield(); proxy.scrollTo(paragraphs.first(where: { $0.line.id == value.lineID })?.id ?? value.lineID, anchor: .top) }
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
                            maximumHeight: available, dismiss: dismissSelection, send: onSendCorrection, applying: correctionSubmitting)
                            .frame(width: width)
                            .position(x: x, y: above ? selection.extent.minY - height / 2 - 10 : selection.extent.maxY + height / 2 + 10)
                            .transition(AnyTransition.scale(scale: 0.92, anchor: above ? .bottom : .top).combined(with: .opacity).combined(with: .movingParts.blur(radius: 4)))
                            .accessibilityIdentifier("composer-correction-popover")
                    }
                } else if showsGlobalComment, reservedHeight >= 30 {
                    // Use the same magic bubble as quote correction, in reserved text-free space.
                    // Its stem follows the working range or the end of the visible draft.
                    let width = min(280, max(100, geometry.size.width - 16))
                    let working = bounds.filter { pendingLineIDs.contains($0.lineID) }.flatMap(\.rects)
                    let anchor = (working.isEmpty ? bounds.flatMap(\.rects) : working).last
                    let anchorX = anchor?.midX ?? geometry.size.width / 2
                    let x = min(max(anchorX, width / 2 + 8), geometry.size.width - width / 2 - 8)
                    let height = max(30, reservedHeight - 8)
                    AlternativesPopover(capturedText: instructionStatus == "Done" ? "" : instructionText,
                        pointX: min(width - 4, max(4, anchorX - x + width / 2)), pointsDown: true,
                        maximumHeight: height, dismiss: { showsInstructionComment = false; onDiscardInstruction() }, send: onSendInstruction,
                        headerTitle: instructionStatus == "Applying" ? "Applying instruction" : "Speak an instruction",
                        dismissLabel: "Discard instruction", applying: instructionStatus == "Applying" || instructionStatus == "Sending",
                        sendLabel: "Apply instruction", accessibilityPrefix: "composer.instruction")
                        .frame(width: width).position(x: x, y: height / 2)
                        .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("composer-instruction-popover")
                }
            } }
            .onAppear { showsInstructionComment = !instructionText.isEmpty && instructionStatus != "Done" }
            .onChange(of: instructionText) { _, text in
                if !text.isEmpty && instructionStatus != "Done" { showsInstructionComment = true }
                else if instructionStatus != "Applying" { showsInstructionComment = false }
            }
            .onChange(of: instructionStatus) { _, status in
                if status == "Done" || status == "Ready" { showsInstructionComment = false }
                else if status == "Applying" || (status == "Listening" && !instructionText.isEmpty) { showsInstructionComment = true }
            }
            .animation(.smooth(duration: 0.22), value: showsInstructionComment)
            .overlay(alignment: .topTrailing) { if busy && !showsGlobalComment { AgentStatusGlyph().padding(8).allowsHitTesting(false) } }
            .animation(animatesDraftChanges ? .smooth(duration: 0.3) : nil, value: snapshot)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selected)
            .onChange(of: isSelecting) { _, active in
                if !active {
                    Task { @MainActor in
                        await Task.yield()
                        if !isSelecting, dragStart != nil { selected = committedSelection; dragStart = nil }
                    }
                }
            }
            .onChange(of: correctionDraft) { old, next in
                if old != nil && next == nil { dismissSelection() }
                else if let selected {
                    reserveForSelection(selected)
                    if reservesSpace {
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(paragraphs.first(where: { $0.line.id == selected.lineID })?.id ?? selected.lineID, anchor: .top)
                        }
                    }
                }
            }
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
    private func reserveForSelection(_ selection: QuoteSelection) {
        if let rect = selectionGeometry(selection)?.extent,
           max(rect.minY - 12, viewportSize.height - rect.maxY - 12) < preferredBubbleHeight { reservesSpace = true }
    }
    private func commit(_ selection: QuoteSelection) {
        reserveForSelection(selection)
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
