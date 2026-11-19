import Foundation

/// The keyboard's side of a staged take (iPhone, #312; `LiveDictationSnapshot.staged`). The app publishes the take's cleanup
/// units in speaking order and the speaking head. This type holds what the keyboard knows of them:
/// - the preview (`preview`): the units not typed yet, then the head, as one text;
/// - the next unit to type (`nextReady`): the first undelivered unit, once its text is final, one at a time;
/// - the take's own record of what it typed (`record`): the context for the separator when the proxy's cannot be trusted;
/// - recovery (`hold`, `resume`): when delivery stops the undelivered units stay in the preview as pending, and the person sends them again.
/// It never edits typed text and it never types anything itself: the controller types each unit through the field queue.
public struct StagedDictation: Sendable, Equatable {
    public private(set) var runID: String?
    private var units: [LiveSegment] = []
    private var head = ""
    private var version = -1
    /// The take ended (every unit is ready); later units can still arrive and are typed too.
    public private(set) var complete = false
    /// The id of the last unit that is in the field (or was empty, so there was nothing to type). Units go in order.
    public private(set) var deliveredThrough: Int?
    /// The unit being typed now.
    public private(set) var inFlight: Int?
    /// Delivery stopped: nothing more is typed until `resume`; the undelivered units stay in the preview (`hold`).
    public private(set) var held = false
    /// What this take typed, in order, exactly as it went into the field.
    public private(set) var record = ""
    private var inFlightText = ""
    /// How many graphemes of the in-flight unit's own text have gone into the field (its separator and capital prefix excluded).
    public private(set) var exited = 0
    /// The unit's first piece has gone out: it is no longer waiting to start.
    public private(set) var started = false

    /// The person cleared the preview and the app has not answered yet: the open unit and the head are hidden at once, so the
    /// clear feels instant. It ends when a snapshot carries the discarded unit (`receive`) or at `endClear`.
    public private(set) var clearing = false

    public struct PreviewDraft: Sendable, Equatable {
        public let unitID: Int
        public let original: String
        public let text: String
        public let sentByHost: Bool
        public fileprivate(set) var released: Bool

        fileprivate init(unit: LiveSegment) {
            unitID = unit.id
            original = unit.previewSource ?? unit.raw ?? unit.text
            text = unit.text
            sentByHost = unit.previewReleased == true
            released = sentByHost
        }
    }

    public private(set) var previewDraft: PreviewDraft?
    public var isAwaitingPreview: Bool {
        pending.first?.editPreview == true && previewDraft == nil
    }

    public var hasPreviewContinuation: Bool {
        !head.isEmpty || pending.dropFirst().contains { $0.discarded != true && !$0.text.isEmpty }
    }

    public init() {}

    /// How much of the record's end the field's context must show for the proxy to count as agreeing with the take.
    static let agreeCharacters = 12
    /// The record keeps only what a separator or a capital can need.
    static let recordCharacters = 400

    /// A unit is confirmed a moment after its last piece went out (its typewriter burst can last seconds). While the queue cannot verify the
    /// field (`hasUnverifiedInput`: after the keyboard came back or the host reported text the proxy had not caught up with)
    /// it will not start it, and nothing in the field may lift that: past this delivery is held and the unit and the rest stay pending in the preview.
    public static let unverifiedStallMs = 2_000.0
    /// Whatever else keeps a unit from being confirmed (a busy host) is bounded too.
    public static let stallMs = 10_000.0

    /// The unit being typed has waited `inFlightMs` without the queue confirming or dropping it: counted from when it began, or
    /// from its latest piece once it started, so a long burst is never cut short. The unverified bound applies only before the
    /// unit starts.
    public func isStalled(inFlightMs: Double, unverifiedInput: Bool) -> Bool {
        inFlight != nil && inFlightMs >= (unverifiedInput && !started ? Self.unverifiedStallMs : Self.stallMs)
    }

    // MARK: Snapshots

    /// A snapshot of the run. A snapshot of another run starts the take over; an older one of the same run is ignored.
    public mutating func receive(_ snapshot: LiveDictationSnapshot) {
        if snapshot.runID != runID { self = StagedDictation(); runID = snapshot.runID }
        guard snapshot.version >= version else { return }
        version = snapshot.version
        units = snapshot.segments.filter(\.final)
        head = snapshot.segments.last(where: { !$0.final })?.text ?? ""
        complete = snapshot.complete
        if units.contains(where: { $0.discarded == true }) { clearing = false }
        if !held { skipEmpty() }
        preparePreviewDraft()
    }

    /// A run this keyboard first sees mid-take (an earlier appearance of the keyboard followed it): the units that appearance
    /// typed (its last receipt, `LiveDictationAck.deliveredThrough`) are not typed again, and a run it held or left stays held, so
    /// its pending units wait for the person's tap and are never retyped on their own. Another run's receipt changes nothing.
    public mutating func adopt(_ ack: LiveDictationAck?) {
        guard let ack, ack.runID == runID, inFlight == nil else { return }
        if let through = ack.deliveredThrough, through > (deliveredThrough ?? -1) { deliveredThrough = through }
        if ack.ended == true || ack.delivered == false { hold() } else if !held { skipEmpty() }
        preparePreviewDraft()
    }

    /// The preview as one text, with where its parts are (character offsets into `text`).
    public struct PreviewLayout: Sendable, Equatable {
        public var text = ""
        /// The unit being typed (a prefix of `text`) and how many of its characters are in the field.
        public var leaving: Range<Int> = 0..<0
        public var exited = 0
        /// Closed units whose cleanup has not landed: sent for cleanup, not yet typed ("thinking"). The open unit is not among them.
        public var waiting: [Range<Int>] = []

        /// The layout of the text without its first `count` characters (the row shows only the end of a long preview).
        public func dropping(_ count: Int) -> PreviewLayout {
            guard count > 0 else { return self }
            func shifted(_ range: Range<Int>) -> Range<Int>? {
                let lower = max(0, range.lowerBound - count), upper = max(0, range.upperBound - count)
                return lower < upper ? lower..<upper : nil
            }
            var result = PreviewLayout()
            result.text = String(text.dropFirst(count))
            result.leaving = shifted(leaving) ?? 0..<0
            result.exited = max(0, exited - count)
            result.waiting = waiting.compactMap(shifted)
            return result
        }
    }

    /// The units not typed yet, in order (raw words until their cleanup landed).
    public var pending: [LiveSegment] {
        units.filter { $0.id > (deliveredThrough ?? -1) }
    }

    /// The undelivered text the preview shows: units (cleaned text replaces raw in place), then the speaking head, with the
    /// parts the row animates. The one derivation of what the keyboard says while dictating.
    public var previewLayout: PreviewLayout {
        var layout = PreviewLayout()
        for unit in pending + [LiveSegment(id: -1, text: head, final: false)] {
            // A discarded unit is not shown (its undo window is open); it is not ready, so delivery waits for it. While the app
            // has not answered a clear, the open unit and the head are hidden the same way.
            guard unit.discarded != true, !(clearing && (unit.id < 0 || unit.closed == false)) else { continue }
            let piece = unit.editPreview == true ? unit.text : unit.text.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if unit.editPreview == true {
                if let first = unit.text.first, LiveSegment.spaced(layout.text.last, first) { layout.text += " " }
                layout.text += unit.text
            } else {
                layout.text = LiveSegment.joined([layout.text, piece])
            }
            let range = (layout.text.count - piece.count)..<layout.text.count
            if unit.id == inFlight {
                layout.leaving = range
                layout.exited = min(exited, piece.count)
            } else if unit.id >= 0, unit.ready != true, unit.closed != false {
                layout.waiting.append(range)
            }
        }
        return layout
    }

    /// What the preview shows (`previewLayout`).
    public var preview: String { previewLayout.text }

    /// A unit the person discarded is waiting out its undo window in the app: the preview hides it and later units wait behind it.
    public var hasDiscarded: Bool { pending.contains { $0.discarded == true } }

    /// There is something a clear would throw away: words in the open unit or the head, not already cleared.
    public var hasDiscardable: Bool {
        !clearing && (!head.isEmpty || pending.contains { $0.closed == false && !$0.text.isEmpty })
    }

    /// The person cleared the preview (`RequestCommand.discard`): hide what it would throw away until the app answers.
    public mutating func clearOpen() { if hasDiscardable { clearing = true } }
    /// The app did not answer the clear (nothing to discard, or the link is slow): the preview shows what is there.
    public mutating func endClear() { clearing = false }

    /// Words are waiting to be typed or still being spoken.
    public var hasUndelivered: Bool { !pending.isEmpty || inFlight != nil }

    /// Everything is in the field (or kept): the take ended and no unit is left.
    public var isFinished: Bool { complete && !hasUndelivered && head.isEmpty }

    /// The first undelivered unit when its text is final and none is being typed.
    public var nextReady: LiveSegment? {
        guard !held, inFlight == nil, let first = pending.first, first.ready == true, !first.text.isEmpty else { return nil }
        if first.editPreview == true, previewDraft?.released != true { return nil }
        return first
    }

    private mutating func skipEmpty() {
        // A unit cleanup dropped whole (all filler) has nothing to type.
        while inFlight == nil, let first = pending.first, first.ready == true, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if first.editPreview == true, first.previewReleased != true { break }
            deliveredThrough = first.id
        }
    }

    private mutating func preparePreviewDraft() {
        guard let first = units.first(where: { $0.id > (deliveredThrough ?? -1) }), first.editPreview == true, first.ready == true else {
            previewDraft = nil
            return
        }
        let next = PreviewDraft(unit: first)
        if let current = previewDraft, current.unitID == next.unitID, current.original == next.original,
           current.text == next.text, current.sentByHost == next.sentByHost { return }
        previewDraft = next
    }

    public mutating func releasePreview() {
        guard let draft = previewDraft, !draft.released else { return }
        if draft.text.isEmpty {
            discardPreviewDraft()
        } else {
            previewDraft?.released = true
        }
    }

    public mutating func discardPreviewDraft() {
        guard let draft = previewDraft, !draft.released else { return }
        deliveredThrough = draft.unitID
        skipEmpty()
        preparePreviewDraft()
    }

    // MARK: Delivery

    /// The last unit that is in the field. The receipt carries it, so a later keyboard appearance knows which units of the take
    /// are still unhandled.
    public var handledThrough: Int? { deliveredThrough }

    /// `unit` is being typed as `typed`.
    public mutating func begin(_ unit: Int, typed: String) {
        inFlight = unit
        inFlightText = typed
        exited = 0; started = false
    }

    /// A piece of the in-flight unit went into the field. Its leading separator is not the unit's own text; every grapheme after
    /// it counts (the capital replaces a letter and adds none; the trailing separator is past the unit's end and is clamped).
    public mutating func sent(_ piece: String) {
        guard let inFlight else { return }
        started = true
        for character in piece {
            if previewDraft?.unitID != inFlight, exited == 0, character.isWhitespace { continue }
            exited += 1
        }
    }

    /// The unit is in the field (the queue confirmed it).
    /// `typed` is what went in when the queue prepared it (separator and capital); else what `begin` said.
    public mutating func delivered(_ unit: Int, typed: String? = nil) {
        guard inFlight == unit else { return }
        inFlight = nil
        exited = 0; started = false
        deliveredThrough = unit
        record += typed ?? inFlightText
        if record.count > Self.recordCharacters { record = String(record.suffix(Self.recordCharacters)) }
        inFlightText = ""
        skipEmpty()
        preparePreviewDraft()
    }

    /// Stops delivery: nothing more is typed. The units not in the field (the one being typed included, it may not have landed)
    /// stay pending, so the preview shows them and `resume` can send them again.
    public mutating func hold() {
        previewDraft?.released = false
        guard !held else { return }
        held = true
        inFlight = nil; inFlightText = ""
        exited = 0; started = false
    }

    /// Delivery goes on from the first unit not in the field (the person moved the caret and sent them again).
    public mutating func resume() {
        guard held else { return }
        held = false
        skipEmpty()
        preparePreviewDraft()
    }

    /// A unit the queue dropped may still be in the field (a key, a tap or a late report spoiled its check after the text went
    /// out). Typing it again would put it there twice: it counts as delivered when a mutation was
    /// issued and the scope shows all of it, or the field's window shows its words. Anything less certain stays pending for the person to send again, never retyped on its own.
    public static func landed(_ drop: FieldQueue.Drop, report: FieldQueue.Report) -> Bool {
        guard drop.issuedMutation else { return false }
        if let partial = drop.partial, partial == drop.text { return true }
        let words = drop.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return false }
        return FieldReader.trusted(before: report.before).contains(words) || report.after.contains(words)
    }

    // MARK: Separator and capital

    /// The text before the caret that a unit's separator and capital follow. The proxy's context while it shows what this take
    /// typed last (or the take typed nothing); otherwise (stale, empty or contradicting) the take's own record. When neither
    /// is known the context is empty and no separator is added: nothing is guessed (#278).
    public func context(proxyBefore: String) -> String {
        guard !record.isEmpty else { return proxyBefore }
        let tail = String(record.suffix(Self.agreeCharacters))
        return proxyBefore.hasSuffix(tail) ? proxyBefore : record
    }
}
