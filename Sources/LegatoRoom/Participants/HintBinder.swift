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

public struct HintEvent: Codable, Sendable, Equatable {
    public var lineID: String
    public var wordID: String
    public var text: String
    public var direct: Bool
}

/// Owns segment insertion. Install on an intercepted Room before starting the transcriber.
public actor HintBinder {
    private let room: Room
    private let learner: VocabularyLearner?
    private var window: WordIntent?
    private var task: Task<Void, Never>?
    public init(room: Room, learner: VocabularyLearner? = nil) { self.room = room; self.learner = learner }
    public func start() async {
        guard task == nil else { return }
        let events = await room.subscribe(participant: .hintBinder, channels: [.asrSegment, .userIntent])
        task = Task { [weak self] in
            for await event in events { guard !Task.isCancelled else { break }; await self?.receive(event) }
        }
    }
    public func stop() { task?.cancel(); task = nil; window = nil }
    public func tap(lineID: String, wordID: String, timestamp: Double) async throws {
        let intent = WordIntent(event: "tap", lineID: lineID, wordID: wordID, timestamp: timestamp)
        window = intent
        try await room.publish(channel: .userIntent, participant: .hintBinder, payload: .encoding(intent), tOrigin: timestamp)
    }
    public func pick(lineID: String, wordID: String, text: String, fromVocabulary: Bool = false) async throws {
        window = nil
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
    private func receive(_ envelope: Envelope) async {
        if envelope.channel == .userIntent {
            guard envelope.participant != .hintBinder, let intent = try? envelope.payload.decode(WordIntent.self) else { return }
            if intent.event == "tap" { window = intent }
            if intent.event == "pick", let text = intent.text {
                try? await pick(lineID: intent.lineID, wordID: intent.wordID, text: text)
            }
            return
        }
        guard let value = envelope.payload["words"], let words = try? value.decode([Word].self) else { return }
        let metadata = envelope.payload["metadata"]
        let start = metadata?["t0"].flatMap { try? $0.decode(Double.self) }
        let end = metadata?["t1"].flatMap { try? $0.decode(Double.self) }
        let audioEnd = envelope.tOrigin + max(0, (end ?? 0) - (start ?? 0))
        if let tap = window, audioEnd >= tap.timestamp - 0.6 {
            window = nil // first completed segment closes the window, including pre-tap speech.
            if envelope.tOrigin >= tap.timestamp, envelope.tOrigin <= tap.timestamp + 4, (1...3).contains(words.count) {
                let text = words.map(\.text).joined(separator: " ")
                do {
                    try await replace(lineID: tap.lineID, wordID: tap.wordID, text: text, fromVocabulary: false)
                    let hint = HintEvent(lineID: tap.lineID, wordID: tap.wordID, text: text, direct: true)
                    try await room.publish(channel: .hint, participant: .hintBinder, payload: .encoding(hint), tOrigin: envelope.tOrigin, causedBy: envelope.id)
                    return
                } catch { /* A vanished target leaves speech as content. */ }
            }
        }
        _ = try? await room.appendSegment(words: words, causedBy: envelope.id)
    }
}
