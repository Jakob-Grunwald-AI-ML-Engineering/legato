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

/// A submitted correction draft addressed to the selected quote, not general dictation.
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

/// Owns correction drafts and one cancellable host countdown; UI only renders its timestamps.
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
        var tail = ""
        var submitting = false
        var sendAt: Double?
        var countdownStart: Double?
        var countdownDeadline: Double?
    }
    private struct InstructionCapture {
        let id = UUID().uuidString
        let snapshot: DocumentSnapshot
        var words: [Word] = []
        var segments: Set<String> = []
        var sources: [JSONValue] = []
        var start: Double
        var end: Double
    }
    private var inputModes: [(time: Double, mode: ComposerInputMode)] = [(-Double.infinity, .dictation)]
    private var untimedMode: ComposerInputMode?
    private var segmentHolds: [String: Int] = [:]
    private var instructionCapture: InstructionCapture?
    private var instructionTail = ""
    private var instructionQuietTask: Task<Void, Never>?
    private let onInstructionQuiet: (@Sendable () async -> Void)?
    private struct Timing: Decodable { let t0: Double?; let t1: Double? }
    private let room: Room
    private let learner: VocabularyLearner?
    private var capture: Capture?
    private var dismissed: [ClosedRange<Double>] = []
    private var suppressUntimedTail = false
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var timerGeneration = UUID()
    private let quietDelay: Duration
    private let countdown: Duration
    private let onSend: (@Sendable () async -> Void)?
    public init(room: Room, learner: VocabularyLearner? = nil, quietDelay: Duration = .milliseconds(500),
                countdown: Duration = .seconds(1), onSend: (@Sendable () async -> Void)? = nil,
                onInstructionQuiet: (@Sendable () async -> Void)? = nil) {
        self.room = room; self.learner = learner; self.quietDelay = quietDelay
        self.countdown = countdown; self.onSend = onSend; self.onInstructionQuiet = onInstructionQuiet
    }
    /// Record a monotonic audio boundary; delayed final tokens retain their original speech channel.
    public func setInputMode(_ mode: ComposerInputMode, timestamp: Double) async {
        inputModes.append((timestamp, mode)); inputModes.sort { $0.time < $1.time }
        _ = try? await room.publish(channel: .session, participant: .hintBinder,
            payload: .object(["event": .string("input.mode.changed"), "inputMode": .string(mode.rawValue)]), tOrigin: timestamp)
    }
    private func inputMode(at time: Double) -> ComposerInputMode {
        inputModes.last(where: { $0.time <= time })?.mode ?? .dictation
    }
    private func instructionActivity() {
        instructionQuietTask?.cancel()
        guard capture == nil, onInstructionQuiet != nil else { return }
        instructionQuietTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)); await self?.finalizeInstructionChunk() } catch {}
        }
    }
    private func finalizeInstructionChunk() async { guard capture == nil else { return }; await onInstructionQuiet?() }
    private func publishInstructionDraft() async {
        let text = [instructionCapture?.words.map(\.text).joined(separator: " ") ?? "", instructionTail]
            .filter { !$0.isEmpty }.joined(separator: " ")
        _ = try? await room.publish(channel: .instructionDraft, participant: .hintBinder,
            payload: .object(["text": .string(text)]))
    }
    private func flushInstruction(_ boundary: Envelope) async {
        instructionQuietTask?.cancel(); instructionQuietTask = nil
        instructionTail = ""
        guard let current = instructionCapture else { await publishInstructionDraft(); return }
        instructionCapture = nil
        if !current.words.isEmpty {
            let payload: JSONValue = .object([
                "event": .string("global.instruction"), "captureID": .string(current.id),
                "text": .string(current.words.map(\.text).joined(separator: " ")),
                "words": (try? .encoding(current.words)) ?? .array([]),
                "snapshot": (try? .encoding(current.snapshot)) ?? .null,
                "documentRevision": .number(Double(current.snapshot.revision)),
                "speechStart": .number(current.start), "speechEnd": .number(current.end),
                "boundary": boundary.payload, "sources": .array(current.sources),
                "instruction": .string("This finalized speech is an explicit instruction about the captured draft, never dictation to append. Apply its meaning with document tools using the full conversation and current writing mode. If the draft is empty, compose what the instruction requests. Preserve facts and pins; do not edit lines added after the captured snapshot. No keyword matching or second writer is involved.")])
            _ = try? await room.publish(channel: .writingInstruction, participant: .hintBinder, payload: payload,
                tOrigin: current.start, baseRev: current.snapshot.revision, causedBy: boundary.id)
        }
        for id in current.segments { await releaseSegment(id) }
        await publishInstructionDraft()
    }
    public func requestSend(timestamp: Double) async -> Bool {
        guard var current = capture, !current.submitting, !draftText(current).isEmpty else { return false }
        cancelTimer()
        current.submitting = true; current.sendAt = timestamp
        current.countdownStart = nil; current.countdownDeadline = nil
        capture = current
        await publishDraft()
        return true
    }
    /// Used when transcription has already drained; otherwise the provider's finalization ack closes send.
    public func completeSend() async {
        guard capture?.submitting == true else { return }
        _ = try? await room.publish(channel: .asrBoundary, participant: .hintBinder,
            payload: .object(["reason": .string("finalize")]))
    }
    private func draftText(_ current: Capture) -> String {
        [current.words.map(\.text).joined(separator: " "), current.tail].filter { !$0.isEmpty }.joined(separator: " ")
    }
    private func publishDraft() async {
        _ = try? await room.publish(channel: .correctionDraft, participant: .hintBinder, payload: .object([
            "text": capture.map { .string(draftText($0)) } ?? .null,
            "captureID": capture.map { .string($0.id) } ?? .null,
            "countdownStart": capture?.countdownStart.map(JSONValue.number) ?? .null,
            "countdownDeadline": capture?.countdownDeadline.map(JSONValue.number) ?? .null]))
    }
    private func cancelTimer() { timer?.cancel(); timer = nil; timerGeneration = UUID() }
    private func activity() async {
        guard var current = capture, !current.submitting, !draftText(current).isEmpty else { await publishDraft(); return }
        cancelTimer()
        current.countdownStart = nil; current.countdownDeadline = nil; capture = current
        let generation = timerGeneration, id = current.id
        timer = Task { [weak self, quietDelay, countdown] in
            do {
                try await Task.sleep(for: quietDelay)
                guard await self?.beginCountdown(id: id, generation: generation) == true else { return }
                try await Task.sleep(for: countdown)
                await self?.autoSend(id: id, generation: generation)
            } catch {}
        }
        await publishDraft()
    }
    private func beginCountdown(id: String, generation: UUID) async -> Bool {
        guard var current = capture, current.id == id, timerGeneration == generation, !current.submitting else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let duration = Double(countdown.components.seconds) + Double(countdown.components.attoseconds) / 1e18
        current.countdownStart = now; current.countdownDeadline = now + duration; capture = current
        await publishDraft()
        return true
    }
    private func autoSend(id: String, generation: UUID) async {
        guard let current = capture, current.id == id, timerGeneration == generation, !current.submitting else { return }
        await onSend?()
    }
    public func start() async {
        guard task == nil else { return }
        let events = await room.subscribe(participant: .hintBinder,
            channels: [.asrSegment, .asrBoundary, .asrRawTail, .userIntent, .session])
        task = Task { [weak self] in
            for await event in events { guard !Task.isCancelled else { break }; await self?.receive(event) }
        }
    }
    public func stop() async { instructionQuietTask?.cancel(); instructionCapture = nil; instructionTail = ""; task?.cancel(); task = nil; dismissed = []; suppressUntimedTail = false; await discardCapture(); await publishDraft() }
    public func tap(lineID: String, wordID: String, timestamp: Double) async throws {
        try await select(lineID: lineID, wordID: wordID, timestamp: timestamp)
    }
    /// Inclusive endpoints in one document snapshot. A word tap is the same range with equal ends.
    public func select(lineID: String, wordID: String, endLineID: String? = nil,
                       endWordID: String? = nil, timestamp: Double) async throws {
        instructionQuietTask?.cancel()
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
        await publishDraft()
    }
    /// Drop captured and still-in-flight speech from the dismissed selection, without targeting new speech.
    public func clearSelection(timestamp: Double) async {
        guard let current = capture else { return }
        dismissed.append(current.discardFrom...max(current.intent.timestamp, timestamp))
        suppressUntimedTail = true
        await discardCapture()
        await publishDraft()
        _ = try? await room.publish(channel: .asrTail, participant: .hintBinder, payload: .object(["text": .string("")]))
    }
    public func pick(lineID: String, wordID: String, text: String, fromVocabulary: Bool = false) async throws {
        await discardCapture()
        await publishDraft()
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
        cancelTimer()
        let ids = capture?.segments ?? []
        capture = nil
        for id in ids { await releaseSegment(id) }
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
            if untimedMode == nil, envelope.payload["activity"] == .bool(true) {
                untimedMode = inputMode(at: envelope.tOrigin)
            }
            if var current = capture {
                if case .array(let parts) = envelope.payload["parts"] {
                    current.tail = parts.filter { part in
                        guard case .number(let time) = part["tOrigin"] else { return true }
                        return time >= current.intent.timestamp && (current.sendAt.map { time <= $0 } ?? true)
                    }.compactMap { if case .string(let text) = $0["text"] { return text }; return nil }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                } else if case .string(let text) = envelope.payload["text"] { current.tail = text }
                capture = current
                if envelope.payload["activity"] == .bool(true), !current.tail.isEmpty { await activity() }
                else { await publishDraft() }
            }
            let payload: JSONValue
            if capture != nil { payload = .object(["text": .string("")]) }
            else if case .array(let parts) = envelope.payload["parts"] {
                let kept = parts.filter { part in
                    guard case .number(let time) = part["tOrigin"] else { return !suppressUntimedTail }
                    return !dismissed.contains { $0.contains(time) }
                }
                instructionTail = kept.filter { part in
                    let time = (try? part["tOrigin"]?.decode(Double.self)) ?? envelope.tOrigin
                    return (part["timed"] == .bool(false) ? untimedMode : inputMode(at: time)) == .instructions
                }.compactMap { if case .string(let text) = $0["text"] { return text }; return nil }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                let text = kept.filter { part in
                    let time = (try? part["tOrigin"]?.decode(Double.self)) ?? envelope.tOrigin
                    return (part["timed"] == .bool(false) ? untimedMode : inputMode(at: time)) != .instructions
                }.compactMap { if case .string(let text) = $0["text"] { return text }; return nil }.joined()
                payload = .object(["text": .string(text)])
            } else if capture == nil, (untimedMode ?? inputMode(at: envelope.tOrigin)) == .instructions {
                instructionTail = (try? envelope.payload["text"]?.decode(String.self)) ?? ""
                payload = .object(["text": .string("")])
            } else { payload = suppressUntimedTail ? .object(["text": .string("")]) : envelope.payload }
            if capture == nil {
                await publishInstructionDraft()
                if !instructionTail.isEmpty, envelope.payload["activity"] == .bool(true) { instructionActivity() }
            }
            _ = try? await room.publish(channel: .asrTail, participant: .hintBinder,
                                       payload: payload, tOrigin: envelope.tOrigin, causedBy: envelope.id)
        case .asrBoundary:
            await flushInstruction(envelope)
            untimedMode = nil
            // Keep audio-time tombstones: late finals may arrive after an endpoint or UI dismissal.
            suppressUntimedTail = false
            guard let current = capture, current.submitting,
                  envelope.payload["reason"] == .string("finalize"), envelope.tOrigin >= current.intent.timestamp else { return }
            cancelTimer()
            capture = nil
            await publishDraft()
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
            for id in current.segments { await releaseSegment(id) }
        case .asrSegment: await routeSegment(envelope)
        case .session:
            if case .string(let event) = envelope.payload["event"],
               ["asr.error", "cancel.work", "done"].contains(event) {
                instructionQuietTask?.cancel(); instructionCapture = nil; instructionTail = ""
                await discardCapture(); await publishDraft(); await publishInstructionDraft()
            }
        default: break
        }
    }
    private func routeSegment(_ envelope: Envelope) async {
        guard let words = try? envelope.payload["words"]?.decode([Word].self) else { return }
        let metadata = envelope.payload["metadata"] ?? .null
        let t0 = (try? metadata["t0"]?.decode(Double.self)) ?? 0
        let timings = (try? metadata["timings"]?.decode([Timing].self)) ?? []
        let remaining: [(word: Word, start: Double, end: Double, mode: ComposerInputMode)] = words.enumerated().compactMap { index, word in
            let timing = timings.indices.contains(index) ? timings[index] : nil
            let start = envelope.tOrigin + max(0, (timing?.t0 ?? t0) - t0)
            let end = envelope.tOrigin + max(0, (timing?.t1 ?? t0) - t0)
            guard !dismissed.contains(where: { $0.contains(start) }) else { return nil }
            let mode = timing?.t0 != nil ? inputMode(at: start) : (untimedMode ?? inputMode(at: start))
            return (word, start, end, mode)
        }
        guard var current = capture else {
            await routeOrdinary(remaining, envelope: envelope)
            return
        }
        var ordinary: [(word: Word, start: Double, end: Double, mode: ComposerInputMode)] = [], targeted: [Word] = []
        for (word, start, end, mode) in remaining {
            if start < current.discardFrom { ordinary.append((word, start, end, mode)) }
            else if let sent = current.sendAt, start > sent { ordinary.append((word, start, end, mode)) }
            else if start >= current.intent.timestamp {
                targeted.append(word); current.start = current.start ?? start; current.end = end
            }
            // Speech belonging to a cancelled selection is consumed, never moved to the draft end.
        }
        if !targeted.isEmpty {
            current.words += targeted; current.tail = ""; current.segments.append(envelope.id)
            segmentHolds[envelope.id, default: 0] += 1
            current.sources.append(.object(["segmentID": .string(envelope.id), "tOrigin": .number(envelope.tOrigin), "metadata": metadata]))
        }
        capture = current
        if !targeted.isEmpty { await activity() }
        await routeOrdinary(ordinary, envelope: envelope, heldByQuote: !targeted.isEmpty)
    }
    private func releaseSegment(_ id: String) async {
        let remaining = (segmentHolds[id] ?? 1) - 1
        if remaining <= 0 { segmentHolds[id] = nil; await room.resolveSegment(id) }
        else { segmentHolds[id] = remaining }
    }
    private func routeOrdinary(_ words: [(word: Word, start: Double, end: Double, mode: ComposerInputMode)],
                               envelope: Envelope, heldByQuote: Bool = false) async {
        // Preserve acoustic order across a channel flip inside one provider segment. Dictation
        // preceding an instruction belongs to its captured draft; later dictation does not.
        var index = 0
        var hasInstructions = false
        while index < words.count {
            let mode = words[index].mode
            let start = index
            while index < words.count, words[index].mode == mode { index += 1 }
            let group = words[start..<index]
            if mode == .dictation {
                _ = try? await room.appendSegment(words: group.map(\.word), causedBy: envelope.id, resolve: false)
            } else {
                hasInstructions = true
                if instructionCapture == nil {
                    instructionCapture = InstructionCapture(snapshot: await room.documentSnapshot,
                        start: group.first!.start, end: group.last!.end)
                }
                instructionCapture?.words += group.map(\.word)
                instructionCapture?.end = group.last!.end
                if instructionCapture?.segments.insert(envelope.id).inserted == true {
                    segmentHolds[envelope.id, default: 0] += 1
                    instructionCapture?.sources.append(.object(["segmentID": .string(envelope.id), "tOrigin": .number(envelope.tOrigin), "metadata": envelope.payload["metadata"] ?? .null]))
                }
                instructionTail = ""; await publishInstructionDraft(); instructionActivity()
            }
        }
        if !hasInstructions && !heldByQuote { await room.resolveSegment(envelope.id) }
    }
}
