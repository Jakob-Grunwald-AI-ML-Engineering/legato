import Foundation
import LegatoComposerDoc
import LegatoVocabulary

/// Keyboard timestamps and segment tOrigin must share the host monotonic clock.
public struct WordIntent: Codable, Sendable, Equatable {
    public var event: String
    public var lineID: String
    public var wordID: String
    public var text: String?
    public var endLineID: String?
    public var endWordID: String?
    public var timestamp: Double
    public init(event: String, lineID: String, wordID: String, endLineID: String? = nil, endWordID: String? = nil, text: String? = nil, timestamp: Double) {
        self.event = event; self.lineID = lineID; self.wordID = wordID; self.text = text; self.timestamp = timestamp
        self.endLineID = endLineID; self.endWordID = endWordID
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
    public var endLineID: String
    public var endWordID: String
    public var endWordIndex: Int
    public var selectedQuote: String
    public var targetLines: [Line]
    public var lineVersions: [String: Int]
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
        let endWordIndex: Int
        let targetLines: [Line]
        let selectedQuote: String
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
    private var dismissed: [ClosedRange<Double>] = []
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
    public func stop() async { task?.cancel(); task = nil; dismissed = []; await discardCapture() }
    public func tap(lineID: String, wordID: String, timestamp: Double) async throws {
        try await select(lineID: lineID, wordID: wordID, timestamp: timestamp)
    }
    /// Inclusive endpoints in one document snapshot. A word tap is the same range with equal ends.
    public func select(lineID: String, wordID: String, endLineID: String? = nil,
                       endWordID: String? = nil, timestamp: Double) async throws {
        let discardFrom = min(capture?.discardFrom ?? timestamp, timestamp)
        await discardCapture()
        let snapshot = await room.documentSnapshot
        guard let a = snapshot.lines.firstIndex(where: { $0.id == lineID }),
              let aw = snapshot.lines[a].words.firstIndex(where: { $0.id == wordID }),
              let b = snapshot.lines.firstIndex(where: { $0.id == (endLineID ?? lineID) }),
              let bw = snapshot.lines[b].words.firstIndex(where: { $0.id == (endWordID ?? wordID) }) else { throw DocumentError.invalidOperation }
        let forward = a < b || (a == b && aw <= bw)
        let first = forward ? a : b, last = forward ? b : a
        let firstWord = forward ? aw : bw, lastWord = forward ? bw : aw
        let lines = Array(snapshot.lines[first...last])
        let quote = lines.enumerated().map { index, line in
            guard !line.words.isEmpty else { return "" }
            let from = index == 0 ? firstWord : 0
            let through = index == lines.count - 1 ? lastWord : line.words.count - 1
            return line.words[from...through].map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
        let startLine = snapshot.lines[first], endLine = snapshot.lines[last]
        let intent = WordIntent(event: "tap", lineID: startLine.id, wordID: startLine.words[firstWord].id,
                                endLineID: endLine.id, endWordID: endLine.words[lastWord].id, timestamp: timestamp)
        capture = Capture(intent: intent, line: startLine, revision: snapshot.revision, wordIndex: firstWord,
                          endWordIndex: lastWord, targetLines: lines, selectedQuote: quote, discardFrom: discardFrom)
        try await room.publish(channel: .userIntent, participant: .hintBinder, payload: .encoding(intent), tOrigin: timestamp)
        try await room.publish(channel: .asrTail, participant: .hintBinder, payload: .object(["text": .string("")]))
    }
    /// Drop captured and still-in-flight speech from the dismissed selection, without targeting new speech.
    public func clearSelection(timestamp: Double) async {
        guard let current = capture else { return }
        dismissed.append(current.discardFrom...max(current.intent.timestamp, timestamp))
        await discardCapture()
        _ = try? await room.publish(channel: .asrTail, participant: .hintBinder, payload: .object(["text": .string("")]))
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
            if intent.event == "tap" {
                try? await select(lineID: intent.lineID, wordID: intent.wordID,
                                  endLineID: intent.endLineID, endWordID: intent.endWordID, timestamp: intent.timestamp)
            }
            if intent.event == "deselect" { await clearSelection(timestamp: intent.timestamp) }
            if intent.event == "pick", let text = intent.text { try? await pick(lineID: intent.lineID, wordID: intent.wordID, text: text) }
        case .asrRawTail:
            let payload = capture == nil && dismissed.isEmpty ? envelope.payload : .object(["text": .string("")])
            _ = try? await room.publish(channel: .asrTail, participant: .hintBinder,
                                       payload: payload, tOrigin: envelope.tOrigin, causedBy: envelope.id)
        case .asrBoundary:
            dismissed.removeAll { envelope.tOrigin >= $0.lowerBound }
            guard let current = capture, envelope.tOrigin >= current.intent.timestamp else { return }
            capture = nil
            if !current.words.isEmpty {
                let hint = HintEvent(event: "targeted.speech", captureID: current.id,
                    lineID: current.line.id, wordID: current.intent.wordID, lineVersion: current.line.version,
                    documentRevision: current.revision, targetLine: current.line, wordIndex: current.wordIndex,
                    endLineID: current.intent.endLineID ?? current.line.id,
                    endWordID: current.intent.endWordID ?? current.intent.wordID, endWordIndex: current.endWordIndex,
                    selectedQuote: current.selectedQuote, targetLines: current.targetLines,
                    lineVersions: Dictionary(uniqueKeysWithValues: current.targetLines.map { ($0.id, $0.version) }),
                    text: current.words.map(\.text).joined(separator: " "), words: current.words,
                    tapTimestamp: current.intent.timestamp, speechStart: current.start ?? envelope.tOrigin,
                    speechEnd: current.end ?? envelope.tOrigin, boundary: envelope.payload, sources: current.sources,
                    instruction: "The user spoke this chunk about selectedQuote, the inclusive word range from lineID/wordID to endLineID/endWordID. A single word is the same range with equal endpoints. Interpret the speech as a correction, insertion or instruction for that quote in context; use document tools at the selection, never append this chunk as general dictation. targetLines and lineVersions capture every selected source line at selection time. If any changed, call view and reconcile before editing. Respect pinned words and version conflicts; if the target vanished, do not append the speech elsewhere.")
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
        let metadata = envelope.payload["metadata"] ?? .null
        let t0 = (try? metadata["t0"]?.decode(Double.self)) ?? 0
        let timings = (try? metadata["timings"]?.decode([Timing].self)) ?? []
        let remaining: [(word: Word, start: Double, end: Double)] = words.enumerated().compactMap { index, word in
            let timing = timings.indices.contains(index) ? timings[index] : nil
            let start = envelope.tOrigin + max(0, (timing?.t0 ?? t0) - t0)
            let end = envelope.tOrigin + max(0, (timing?.t1 ?? t0) - t0)
            guard !dismissed.contains(where: { $0.contains(start) }) else { return nil }
            return (word, start, end)
        }
        guard var current = capture else {
            if remaining.isEmpty { await room.resolveSegment(envelope.id) }
            else { _ = try? await room.appendSegment(words: remaining.map(\.word), causedBy: envelope.id) }
            return
        }
        var ordinary: [Word] = [], targeted: [Word] = []
        for (word, start, end) in remaining {
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
