import Foundation

/// The keyboard's side of a staged take (iPhone, #312; `LiveDictationSnapshot.staged`). The app publishes the take's cleanup
/// units in speaking order and the speaking head. This type holds what the keyboard knows of them:
/// - the preview (`preview`): the units not typed yet, then the head, as one text;
/// - the next unit to type (`nextReady`): the first undelivered unit, once its text is final, one at a time;
/// - the take's own record of what it typed (`record`): the source of the separator when the proxy's context cannot be trusted;
/// - recovery (`hold`): what goes to the kept-text row when delivery stops.
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
    /// Delivery stopped: nothing more is typed, what remains went to recovery (`hold`).
    public private(set) var held = false
    private var keptThrough: Int?
    /// Everything handed to recovery so far, in order: what the kept-text row shows for this take.
    public private(set) var kept = ""
    /// What this take typed, in order, exactly as it went into the field.
    public private(set) var record = ""
    private var inFlightText = ""

    public init() {}

    /// How much of the record's end the field's context must show for the proxy to count as agreeing with the take.
    static let agreeCharacters = 12
    /// The record keeps only what a separator or a capital can need.
    static let recordCharacters = 400

    /// A unit never stays held: it is typed and confirmed within a few hundred milliseconds. While the queue cannot verify the
    /// field (`hasUnverifiedInput`: after the keyboard came back or the host reported text the proxy had not caught up with)
    /// it will not start it, and nothing in the field may lift that: past this the unit and the rest go to the kept-text row.
    public static let unverifiedStallMs = 2_000.0
    /// Whatever else keeps a unit from being confirmed (a busy host) is bounded too.
    public static let stallMs = 10_000.0

    /// The unit being typed has waited `inFlightMs` without the queue confirming or dropping it.
    public func isStalled(inFlightMs: Double, unverifiedInput: Bool) -> Bool {
        inFlight != nil && inFlightMs >= (unverifiedInput ? Self.unverifiedStallMs : Self.stallMs)
    }

    // MARK: Snapshots

    /// A snapshot of the run. Returns `kept` when delivery is held and units that became ready after the hold were added to
    /// it, else nil. A snapshot of another run starts the take over; an older one of the same run is ignored.
    @discardableResult
    public mutating func receive(_ snapshot: LiveDictationSnapshot) -> String? {
        if snapshot.runID != runID { self = StagedDictation(); runID = snapshot.runID }
        guard snapshot.version >= version else { return nil }
        version = snapshot.version
        units = snapshot.segments.filter(\.final)
        head = snapshot.segments.last(where: { !$0.final })?.text ?? ""
        complete = snapshot.complete
        if held { return keepReady() }
        skipEmpty()
        return nil
    }

    /// The units not typed yet, in order (raw words until their cleanup landed).
    public var pending: [LiveSegment] {
        if held { return [] }
        return units.filter { $0.id > (deliveredThrough ?? -1) }
    }

    /// The undelivered text the preview shows: units (cleaned text replaces raw in place), then the speaking head.
    /// The one derivation of what the keyboard says while dictating.
    public var preview: String { LiveSegment.joined(pending.map(\.text) + [head]) }

    /// Words are waiting to be typed or still being spoken.
    public var hasUndelivered: Bool { !pending.isEmpty || inFlight != nil }

    /// Everything is in the field (or kept): the take ended and no unit is left.
    public var isFinished: Bool { complete && !hasUndelivered && head.isEmpty }

    /// The first undelivered unit when its text is final and none is being typed.
    public var nextReady: LiveSegment? {
        guard !held, inFlight == nil, let first = pending.first, first.ready == true, !first.text.isEmpty else { return nil }
        return first
    }

    private mutating func skipEmpty() {
        // A unit cleanup dropped whole (all filler) has nothing to type.
        while inFlight == nil, let first = pending.first, first.ready == true, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliveredThrough = first.id
        }
    }

    // MARK: Delivery

    /// `unit` is being typed as `typed`.
    public mutating func begin(_ unit: Int, typed: String) {
        inFlight = unit
        inFlightText = typed
    }

    /// The unit is in the field (the queue confirmed it).
    public mutating func delivered(_ unit: Int) {
        guard inFlight == unit else { return }
        inFlight = nil
        deliveredThrough = unit
        record += inFlightText
        if record.count > Self.recordCharacters { record = String(record.suffix(Self.recordCharacters)) }
        inFlightText = ""
        skipEmpty()
    }

    /// Stops delivery: the units not in the field (the one being typed included, it may not have landed) go to `kept`, which
    /// is returned. Units that become ready later are added by `receive`. Nil when nothing is left.
    @discardableResult
    public mutating func hold() -> String? {
        guard !held else { return nil }
        let texts = pending.map(\.text)
        keptThrough = pending.last?.id ?? deliveredThrough
        held = true
        inFlight = nil; inFlightText = ""
        return keep(texts)
    }

    private mutating func keepReady() -> String? {
        var texts: [String] = []
        for unit in units where unit.id > (keptThrough ?? -1) {
            guard unit.ready == true else { break }
            texts.append(unit.text)
            keptThrough = unit.id
        }
        return keep(texts)
    }

    private mutating func keep(_ texts: [String]) -> String? {
        let text = LiveSegment.joined(texts)
        guard !text.isEmpty else { return nil }
        kept = LiveSegment.joined([kept, text])
        return kept
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

    /// What the field gets for `text`: its separator, capitalized where the field's own rules would, and a space when it ends
    /// up against the word after the caret. One insert; the queue types it with the entrance.
    public func prepared(_ text: String, proxyBefore: String, after: Character?, capitalization: AutoCapitalizationType) -> String {
        let typed = FieldInsertion.prepare(text, contextBefore: context(proxyBefore: proxyBefore), capitalization: capitalization)
        return typed.isEmpty ? "" : typed + FieldInsertion.trailingSeparator(after: typed, before: after)
    }
}
