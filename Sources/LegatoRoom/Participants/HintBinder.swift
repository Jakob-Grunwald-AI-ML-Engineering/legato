import Foundation
import LegatoComposerDoc
import LegatoVocabulary

/// Keyboard timestamps and segment tOrigin must share the host monotonic clock.
public struct WordIntent: Codable, Sendable, Equatable {
    public var event: String
    public var lineID: String
    public var wordID: String
    public var text: String?
    public var timestamp: Double
    public init(event: String, lineID: String, wordID: String, text: String? = nil, timestamp: Double) {
        self.event = event; self.lineID = lineID; self.wordID = wordID; self.text = text; self.timestamp = timestamp
    }
}

/// A silence-delimited utterance addressed to a selected word, not general dictation.
public struct HintEvent: Codable, Sendable, Equatable {
    public var event: String
    public var captureID: String
    public var lineID: String
    public var wordID: String
    public var lineVersion: Int
    public var documentRevision: Int
    public var targetLine: Line
    public var wordIndex: Int
    public var text: String
    public var words: [Word]
    public var tapTimestamp: Double
    public var speechStart: Double
    public var speechEnd: Double
    public var boundary: JSONValue
    public var sources: [JSONValue]
    public var instruction: String
}

/// Owns segment and partial-tail routing. No independent hint timeout or silence timer.
public actor HintBinder {
    private struct Capture {
        let intent: WordIntent
        let line: Line
        let revision: Int
        let wordIndex: Int
        let id = UUID().uuidString
        let discardFrom: Double
        var words: [Word] = []
        var start: Double?
        var end: Double?
        var segments: [String] = []
        var sources: [JSONValue] = []
    }
    private struct Timing: Decodable { let t0: Double?; let t1: Double? }
    private let room: Room
    private let learner: VocabularyLearner?
    private var capture: Capture?
    private var task: Task<Void, Never>?
    public init(room: Room, learner: VocabularyLearner? = nil) { self.room = room; self.learner = learner }
    public func start() async {
        guard task == nil else { return }
        let events = await room.subscribe(participant: .hintBinder,
            channels: [.asrSegment, .asrBoundary, .asrRawTail, .userIntent, .session])
        task = Task { [weak self] in
            for await event in events { guard !Task.isCancelled else { break }; await self?.receive(event) }
        }
    }
    public func stop() async { task?.cancel(); task = nil; await discardCapture() }
    public func tap(lineID: String, wordID: String, timestamp: Double) async throws {
        let discardFrom = min(capture?.discardFrom ?? timestamp, timestamp)
        await discardCapture()
        let snapshot = await room.documentSnapshot
        guard let line = snapshot.lines.first(where: { $0.id == lineID }),
              let index = line.words.firstIndex(where: { $0.id == wordID }) else { throw DocumentError.unknownLine(lineID) }
        let intent = WordIntent(event: "tap", lineID: lineID, wordID: wordID, timestamp: timestamp)
        capture = Capture(intent: intent, line: line, revision: snapshot.revision,
                          wordIndex: index, discardFrom: discardFrom)
        try await room.publish(channel: .userIntent, participant: .hintBinder, payload: .encoding(intent), tOrigin: timestamp)
        try await room.publish(channel: .asrTail, participant: .hintBinder, payload: .object(["text": .string("")]))
    }
    public func pick(lineID: String, wordID: String, text: String, fromVocabulary: Bool = false) async throws {
        await discardCapture()
        try await replace(lineID: lineID, wordID: wordID, text: text, fromVocabulary: fromVocabulary)
        let intent = WordIntent(event: "pick", lineID: lineID, wordID: wordID, text: text, timestamp: ProcessInfo.processInfo.systemUptime)
        try await room.publish(channel: .userIntent, participant: .hintBinder, payload: .encoding(intent))
    }
    private func replace(lineID: String, wordID: String, text: String, fromVocabulary: Bool) async throws {
        let snapshot = await room.documentSnapshot
        guard let line = snapshot.lines.first(where: { $0.id == lineID }),
              let word = line.words.first(where: { $0.id == wordID }) else { throw DocumentError.unknownLine(lineID) }
        try await room.applyDocument([.pinWord(lineID: lineID, wordID: wordID, text: text)], origin: .user, versions: [lineID: line.version])
        await learner?.recordChoice(original: word.text, chosen: text, fromVocabulary: fromVocabulary)
    }
    private func discardCapture() async {
        let ids = capture?.segments ?? []
        capture = nil
        for id in ids { await room.resolveSegment(id) }
    }
    private func receive(_ envelope: Envelope) async {
        switch envelope.channel {
        case .userIntent:
            guard envelope.participant != .hintBinder, let intent = try? envelope.payload.decode(WordIntent.self) else { return }
            if intent.event == "tap" { try? await tap(lineID: intent.lineID, wordID: intent.wordID, timestamp: intent.timestamp) }
            if intent.event == "pick", let text = intent.text { try? await pick(lineID: intent.lineID, wordID: intent.wordID, text: text) }
        case .asrRawTail:
            let payload = capture == nil ? envelope.payload : .object(["text": .string("")])
            _ = try? await room.publish(channel: .asrTail, participant: .hintBinder,
                                       payload: payload, tOrigin: envelope.tOrigin, causedBy: envelope.id)
        case .asrBoundary:
            guard let current = capture, envelope.tOrigin >= current.intent.timestamp else { return }
            capture = nil
            if !current.words.isEmpty {
                let hint = HintEvent(event: "targeted.speech", captureID: current.id,
                    lineID: current.line.id, wordID: current.intent.wordID, lineVersion: current.line.version,
                    documentRevision: current.revision, targetLine: current.line, wordIndex: current.wordIndex,
                    text: current.words.map(\.text).joined(separator: " "), words: current.words,
                    tapTimestamp: current.intent.timestamp, speechStart: current.start ?? envelope.tOrigin,
                    speechEnd: current.end ?? envelope.tOrigin, boundary: envelope.payload, sources: current.sources,
                    instruction: "The user spoke this chunk at the tapped word. Interpret it in the surrounding draft as a correction, insertion or instruction for that location; use document tools there, never append this chunk as general dictation. targetLine and wordIndex identify the selected location at lineVersion. If it changed, call view and reconcile before editing. Respect pinned words and version conflicts; if the target vanished, do not append the speech elsewhere.")
                _ = try? await room.publish(channel: .hint, participant: .hintBinder, payload: .encoding(hint),
                                            tOrigin: current.start, baseRev: current.revision, causedBy: envelope.id)
            }
            for id in current.segments { await room.resolveSegment(id) }
        case .asrSegment: await routeSegment(envelope)
        case .session:
            if case .string(let event) = envelope.payload["event"],
               ["asr.finished", "asr.error", "cancel.work", "done"].contains(event) { await discardCapture() }
        default: break
        }
    }
    private func routeSegment(_ envelope: Envelope) async {
        guard let words = try? envelope.payload["words"]?.decode([Word].self) else { return }
        guard var current = capture else {
            _ = try? await room.appendSegment(words: words, causedBy: envelope.id)
            return
        }
        let metadata = envelope.payload["metadata"] ?? .null
        let t0 = (try? metadata["t0"]?.decode(Double.self)) ?? 0
        let timings = (try? metadata["timings"]?.decode([Timing].self)) ?? []
        var ordinary: [Word] = [], targeted: [Word] = []
        for (index, word) in words.enumerated() {
            let timing = timings.indices.contains(index) ? timings[index] : nil
            let start = envelope.tOrigin + max(0, (timing?.t0 ?? t0) - t0)
            let end = envelope.tOrigin + max(0, (timing?.t1 ?? t0) - t0)
            if start < current.discardFrom { ordinary.append(word) }
            else if start >= current.intent.timestamp {
                targeted.append(word); current.start = current.start ?? start; current.end = end
            }
            // Speech belonging to a cancelled selection is consumed, never moved to the draft end.
        }
        if !targeted.isEmpty {
            current.words += targeted; current.segments.append(envelope.id)
            current.sources.append(.object(["segmentID": .string(envelope.id), "tOrigin": .number(envelope.tOrigin), "metadata": metadata]))
        }
        capture = current
        if !ordinary.isEmpty {
            _ = try? await room.appendSegment(words: ordinary, causedBy: envelope.id, resolve: targeted.isEmpty)
        } else if targeted.isEmpty { await room.resolveSegment(envelope.id) }
    }
}
