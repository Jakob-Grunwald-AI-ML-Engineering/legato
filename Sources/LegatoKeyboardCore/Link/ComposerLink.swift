import Foundation
import LegatoComposerDoc
import os

public struct ComposerPublication: Codable, Equatable, Sendable {
    public var snapshot: DocumentSnapshot
    public var hunks: [AnimationHunk]
    public var requiresSnapshot: Bool
    public var sessionID: String?
    public var tail = ""
    /// Advances only after validated dictation is appended, never on an agent rewrite.
    public var dictationRevision: Int?
    public var dictationCommit: DictationCommit?
    /// Successful target delivery only; unlike insertedIntentID this never acknowledges a rejection.
    public var successfulInsertionID: String?
    public var mode = "message"
    public var status = "idle"
    /// Optional for compatibility with older hosts; never used as the session lifecycle state.
    public var voiceIsolationStatus: String?
    public var error: String?
    public var pendingLineIDs: Set<String> = []
    public var busy = false
    /// nil decodes legacy publications written before voice mute was available.
    public var correctionDraft: String?
    public var correctionSubmitting: Bool?
    public var correctionCountdownStart: Double?
    public var correctionCountdownDeadline: Double?
    public var muted: Bool?
    /// Legacy Dictation/Instructions toggle; no longer published (the surface decides the mode).
    /// Where microphone audio goes now (`idle`, `dictation`, `agent`); nil before keyboard sessions.
    public var audioRoute: String?
    /// The dictation route's uncommitted words, for the typing surface.
    public var dictationTail: String?
    /// Why the last tap on the dictation route could not start, and a counter that changes with each notice.
    public var dictationNotice: String?
    public var dictationNoticeID: Int?
    /// The take held for one write (on stop / after a pause): its text so far (buffered, in cleanup or failed),
    /// its phase (`buffering`, `cleaning`, `failed`) and the pause countdown (host `systemUptime`); nil in
    /// line-by-line mode and with older hosts.
    public var dictationTake: String?
    public var dictationTakePhase: String?
    public var dictationCountdownStart: Double?
    public var dictationCountdownDeadline: Double?
    public var instructionDraft: String?
    public var instructionStatus: String?
    /// Automatic-send countdown over the pending instruction (host `systemUptime`); nil in manual mode.
    public var instructionCountdownStart: Double?
    public var instructionCountdownDeadline: Double?
    /// The last keyboard insertion consumed by the host (including a stale-session rejection).
    public var insertedIntentID: String?
    public init(snapshot: DocumentSnapshot = .init(revision: 0, lines: []), hunks: [AnimationHunk] = [], requiresSnapshot: Bool = false) {
        self.snapshot = snapshot; self.hunks = hunks; self.requiresSnapshot = requiresSnapshot
    }
}

/// Every value contains the current snapshot and all animation hunks since the acknowledged revision.
/// The snapshot makes missed notifications and bounded history recovery deterministic.
public struct ComposerLinkHistory: Sendable {
    private var current = DocumentSnapshot(revision: 0, lines: [])
    private var revisions: [(Int, [AnimationHunk])] = []
    public init() {}
    public mutating func record(_ snapshot: DocumentSnapshot, hunks: [AnimationHunk]) {
        current = snapshot; revisions.append((snapshot.revision, hunks))
        if revisions.count > 100 { revisions.removeFirst(revisions.count - 100) }
    }
    /// True when `snapshot` is not what the history already holds. A revision number alone is not enough:
    /// a restarted document can reuse a revision with different lines.
    public func needsRecord(_ snapshot: DocumentSnapshot) -> Bool {
        revisions.last?.0 != snapshot.revision || current != snapshot
    }
    public func publication(acknowledged: Int) -> ComposerPublication {
        let oldest = revisions.first?.0 ?? current.revision + 1
        let gap = acknowledged < oldest - 1 || acknowledged > current.revision
        return .init(snapshot: current, hunks: gap ? [] : revisions.filter { $0.0 > acknowledged }.flatMap { $0.1 }, requiresSnapshot: gap)
    }
}

public struct ComposerIntent: Codable, Equatable, Sendable {
    public var id: String
    public var action: String
    public var lineID: String?
    public var wordID: String?
    public var text: String?
    public var endLineID: String?
    public var endWordID: String?
    public var sessionID: String?
    public var timestamp: Double
    public init(action: String, lineID: String? = nil, wordID: String? = nil, endLineID: String? = nil, endWordID: String? = nil, text: String? = nil, sessionID: String? = nil) {
        id = UUID().uuidString; self.action = action; self.lineID = lineID; self.wordID = wordID; self.text = text
        self.endLineID = endLineID; self.endWordID = endWordID
        self.sessionID = sessionID
        timestamp = ProcessInfo.processInfo.systemUptime
    }


}

public struct ComposerLink: Sendable {
    public let store: LinkStore
    public init(store: LinkStore) { self.store = store }
    public func publish(_ value: ComposerPublication) { store.write(value, forKey: LinkChannel.Key.composer) }
    public func read() -> ComposerPublication? { store.read(ComposerPublication.self, forKey: LinkChannel.Key.composer) }
    /// Size of the stored publication, for diagnostics only.
    public var storedByteCount: Int? { encodedPublication?.count }
    public func acknowledge(_ revision: Int) { store.write(revision, forKey: LinkChannel.Key.composerAck) }
    public var acknowledged: Int { store.read(Int.self, forKey: LinkChannel.Key.composerAck) ?? 0 }
    public func send(_ intent: ComposerIntent) { store.write(intent, forKey: LinkChannel.Key.composerIntentPrefix + intent.id) }
    public func drainIntents() -> [ComposerIntent] {
        store.keys(withPrefix: LinkChannel.Key.composerIntentPrefix).compactMap { key in
            defer { store.remove(forKey: key) }
            return store.read(ComposerIntent.self, forKey: key)
        }.sorted { $0.timestamp < $1.timestamp }
    }
}

/// A logical equality check happens before JSON encoding or touching preferences. The exact bytes
/// are retained so an unexpectedly removed/changed backing value can be restored without encoding.
public struct ComposerPublicationPublisher: Sendable {
    private var previous: ComposerPublication?
    private var encoded: Data?
    private var failedEncoding: ComposerPublication?
    public init() {}
    @discardableResult public mutating func publish(_ value: ComposerPublication, through link: ComposerLink) -> Bool {
        let data: Data
        if value == previous, let encoded {
            if link.encodedPublication == encoded { return false }
            data = encoded
        } else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = .sortedKeys   // equal values give equal bytes
            // A stray NaN/infinity must degrade to a string, not silently drop the whole publication.
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            let next: Data
            do { next = try encoder.encode(value) } catch {
                // Logged once per distinct value: the host retries every tick.
                if failedEncoding != value {
                    failedEncoding = value
                    ComposerLinkLog.logger.error("composer.publish encode failed rev=\(value.snapshot.revision) lines=\(value.snapshot.lines.count) \(ComposerLinkLog.describe(error), privacy: .public)")
                }
                return false
            }
            failedEncoding = nil
            // Unchanged bytes (e.g. a NaN field never compares equal) are not a new publication.
            if next == encoded, link.encodedPublication == next { previous = value; return false }
            data = next
        }
        link.store.writeEncodedData(data, forKey: LinkChannel.Key.composer)
        guard link.encodedPublication == data else {
            ComposerLinkLog.logger.error("composer.publish write not readable back bytes=\(data.count) rev=\(value.snapshot.revision)")
            return false
        }
        previous = value; encoded = data
        return true
    }
}

/// Read fresh bytes, but decode a publication only when those bytes change. Bytes that fail to decode are
/// logged and remembered only until the bytes change or `reset()`, so a malformed publication cannot burn
/// the keyboard's main thread, and a new appearance always starts from a clean read.
public struct ComposerPublicationReader: Sendable {
    private var encoded: Data?
    /// Byte count of the last publication that failed to decode; nil once a later one decodes.
    public private(set) var lastDecodeFailureBytes: Int?
    public init() {}
    /// Forget the bytes seen so far: the next `read` decodes whatever is stored now.
    public mutating func reset() { encoded = nil; lastDecodeFailureBytes = nil }
    public mutating func read(from link: ComposerLink) -> ComposerPublication? {
        guard let data = link.encodedPublication else { encoded = nil; return nil }
        guard data != encoded else { return nil }
        encoded = data
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do {
            let value = try decoder.decode(ComposerPublication.self, from: data)
            lastDecodeFailureBytes = nil
            return value
        } catch {
            lastDecodeFailureBytes = data.count
            ComposerLinkLog.logger.error("composer.read decode failed bytes=\(data.count) \(ComposerLinkLog.describe(error), privacy: .public)")
            return nil
        }
    }
}

/// Logging for the composer link. Messages carry counts and coding paths, never draft text.
enum ComposerLinkLog {
    static let logger = Logger(subsystem: "de.gruenwald.legato", category: "composer-link")
    static func describe(_ error: Error) -> String {
        func path(_ context: [CodingKey]) -> String { "path=" + context.map(\.stringValue).joined(separator: ".") }
        if let error = error as? DecodingError {
            switch error {
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c): return path(c.codingPath)
            @unknown default: return "decoding"
            }
        }
        if let error = error as? EncodingError, case .invalidValue(_, let c) = error { return path(c.codingPath) }
        return String(describing: type(of: error))
    }
}

private extension ComposerLink {
    var encodedPublication: Data? { store.encodedData(forKey: LinkChannel.Key.composer) }
}
