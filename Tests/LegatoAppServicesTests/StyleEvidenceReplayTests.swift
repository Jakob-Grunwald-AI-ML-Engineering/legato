import Foundation
import LegatoAgent
import LegatoClaude
import LegatoCore
import LegatoRoom
import Synchronization
import Testing

private let styleCue = "A light emoji is welcome when it fits this message."
private enum Policy: String, CaseIterable { case unchanged, anyOrigin, attributed }

private struct Probe {
    let draft: String
    let context: StyleEvent.Context
    let wanted: Bool
    var platform: StyleEvent.Platform = .iOS
    var mode: DictationCleanupStyle? = .send
    var instruction: String?

    func suggests(_ policy: Policy, history: StyleReplay, request: StyleEvent) -> Bool {
        guard mode == .send, instruction == nil else { return false }
        let observations = history.active(on: platform, excluding: request.takeID)
        switch policy {
        case .unchanged: return false
        case .anyOrigin: return observations.filter { $0.addedByAnyone > 0 }.count >= 2
        case .attributed: return history.shadowDecision(at: request) == .cue
        }
    }
}

/// Intercept exactly the bytes the production transport would receive. The intercepted request never leaves memory.
private final class OfflineRequest: MessagesStreaming {
    private let captured = Mutex<Data?>(nil)
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        captured.withLock { $0 = request }
        return AsyncThrowingStream { $0.finish() }
    }

    func body(for probe: Probe, suggest: Bool) async throws -> JSONValue? {
        guard let mode = probe.mode else { return nil }
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        // Override both settings in an isolated, volatile domain, including for the baseline.
        defaults.setVolatileDomain([ComposerWritingSettings.promptKey: suggest ? styleCue : "",
                                    ComposerWritingSettings.modelKey: ModelChoice.haiku.rawValue], forName: UserDefaults.argumentDomain)
        let input = SentenceCleanupInput(sentenceID: "fixture", sequence: 0, text: probe.draft, vocabulary: [],
                                         dictation: .init(style: mode, instructions: probe.instruction),
                                         writingSettings: .init(in: defaults))
        do { _ = try await SentenceCleanupClient(client: self).clean(input) }
        catch SentenceCleanupError.incomplete { /* Expected; the local transport provides no model output. */ }
        return try JSONDecoder().decode(JSONValue.self, from: #require(captured.withLock { $0 }))
    }
}

private struct Score {
    var desired = 0, missed = 0, leakage = 0, appropriateSilence = 0, requests = 0, suppressedRequests = 0
    mutating func observe(_ wire: JSONValue?, probe: Probe) throws {
        guard let wire else { suppressedRequests += 1; return }
        requests += 1
        let system = try #require(wire["system"]).decode([JSONValue].self)
        let prompt = try #require(system.first?["text"]).decode(String.self)
        let cue = prompt.contains(styleCue)
        switch (cue, probe.wanted) {
        case (true, true): desired += 1
        case (true, false): leakage += 1
        case (false, true): missed += 1
        case (false, false): appropriateSilence += 1
        }
        let messages = try #require(wire["messages"]).decode([JSONValue].self)
        let content = try #require(messages.first?["content"]).decode(String.self)
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
        #expect(payload["text"] == .string(probe.draft))
        #expect(payload["instructions"] == probe.instruction.map(JSONValue.string))
    }
}

@Suite struct StyleEvidenceReplayTests {
    @Test func heldOutSessions() async throws {
        var rows: [StyleEvent] = []
        var history = StyleReplay()
        var scores: [Policy: Score] = [:]
        var sessionDay = 1
        func observe(_ action: StyleEvent.Action, take: Int, platform: StyleEvent.Platform = .iOS,
                     context: StyleEvent.Context = .sendField, before: String = "", after: String = "",
                     instruction: String? = nil) throws {
            let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", take)))
            let event = StyleEvent(takeID: id, platform: platform, action: action, context: context, before: before,
                                   after: after, instruction: instruction, at: Date(timeIntervalSince1970: Double(86_400 * sessionDay + rows.count + 1)))
            rows.append(event)
            try history.observe(event, line: rows.count)
        }
        func probe(_ probe: Probe) async throws {
            let event = StyleEvent(takeID: UUID(), platform: probe.platform, action: .request, context: probe.context,
                                   instruction: probe.instruction, at: Date(timeIntervalSince1970: Double(86_400 * sessionDay + rows.count + 1)),
                                   mode: probe.mode.map { $0 == .send ? .send : .line } ?? .off)
            if probe.mode != nil {
                rows.append(event)
                try history.observe(event, line: rows.count)
            }
            for policy in Policy.allCases {
                let body = try await OfflineRequest().body(for: probe, suggest: probe.suggests(policy, history: history, request: event))
                try scores[policy, default: .init()].observe(body, probe: probe)
            }
        }

        // Earlier sessions. An inserted model answer and a subsequently cleared field are two events in one take.
        try observe(.magic, take: 1, before: "Danke", after: "Danke 🙂", instruction: "add an emoji")
        try observe(.inserted, take: 1)
        try observe(.boundary, take: 1)
        try observe(.cleanup, take: 2, before: "Super", after: "Super ✨")
        try observe(.magic, take: 3, after: "Später 🙂", instruction: "make it friendlier")
        try observe(.magic, take: 4, after: "Bis dann 👋", instruction: "make it warmer")
        try observe(.magic, take: 5, after: "Cool 🎉", instruction: "rewrite this")
        try observe(.magic, take: 6, after: "Danke 🙃", instruction: "rewrite this")
        try observe(.deleted, take: 6)
        try observe(.magic, take: 7, before: "Hi 👋", after: "Hi", instruction: "no emoji")
        sessionDay = 2
        try observe(.hostEdit, take: 8, before: "Ja", after: "Ja 👍")
        try observe(.typed, take: 9, context: .unknown, after: "🙂")
        try observe(.finalized, take: 10)  // Ordinary finalized take; cleanup was skipped.
        try observe(.typed, take: 10, after: "🙂")
        try observe(.typed, take: 10, before: "🙂", after: "🙂🎉")      // Same take.
        try observe(.typed, take: 11, after: "🎉")
        try observe(.typed, take: 11, before: "🎉", after: "")        // Reversal before insertion.
        try observe(.magic, take: 12, platform: .macOS, context: .unknown, after: "Nice 🙂", instruction: "add an emoji")

        // Each later session sees only previous events. Labels describe the fixture writer's intent independently of rules.
        sessionDay = 3
        try await probe(.init(draft: "Let's meet at eight", context: .sendField, wanted: true))
        try observe(.suggestion, take: 13, before: "Until then", after: "Until then 👋")
        let repeated = try #require(rows.last)
        rows.append(repeated)
        try history.observe(repeated, line: rows.count)
        try await probe(.init(draft: "Bis später", context: .sendField, wanted: true))
        try await probe(.init(draft: "That was so much fun", context: .sendField, wanted: true))
        try await probe(.init(draft: "The database schemas are approved", context: .unknown, wanted: false))
        try await probe(.init(draft: "Please confirm the contract amendment", context: .sendField, wanted: false))
        try await probe(.init(draft: "Kemas sent the revised proposal", context: .unknown, wanted: false))
        try await probe(.init(draft: "Danke für die Einladung", context: .sendField, wanted: false, instruction: "no emoji"))
        try await probe(.init(draft: "Patrice spoke to Badhri", context: .sendField, wanted: false, mode: .line))
        try await probe(.init(draft: "See you then", context: .sendField, wanted: false, mode: nil))
        try await probe(.init(draft: "We have the notes", context: .unknown, wanted: false, platform: .macOS))

        sessionDay = 4
        try observe(.undo, take: 13, before: "Until then 👋", after: "Until then")
        try await probe(.init(draft: "Appointment recorded", context: .sendField, wanted: false))
        try observe(.deleted, take: 10)
        try await probe(.init(draft: "Meeting recorded", context: .sendField, wanted: false))

        for policy in Policy.allCases {
            let s = try #require(scores[policy])
            print("synthetic \(policy.rawValue) requests=\(s.requests) off=\(s.suppressedRequests) wantedCue=\(s.desired) missed=\(s.missed) unwantedCue=\(s.leakage) appropriateSilence=\(s.appropriateSilence)")
            #expect(s.requests == 11 && s.suppressedRequests == 1)
        }
        let result = try #require(scores[.attributed])
        #expect(result.desired == 2 && result.missed == 1 && result.leakage == 1)
        #expect(result.leakage < scores[.anyOrigin, default: .init()].leakage)

        // Run the export reader on wire JSONL too; benchmark packet size before any reviewer prompt/response is added.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = Data()
        for row in rows { bytes.append(try encoder.encode(row)); bytes.append(10) }
        let imported = try StyleReplay.read(bytes)
        #expect(history.describe() == imported.describe())
        #expect(imported.duplicates == 1)
        #expect(imported.shadowDecisions[StyleReplay.Decision.cue.rawValue] == result.desired + result.leakage)
        let candidates = imported.reviewCandidates(on: .iOS)
        #expect(candidates.count == 3)
        // This is an estimate of data volume, not an actual classification request or tokenizer.
        // Batches are planned only at this synthetic idle checkpoint. An incomplete batch waits.
        for size in [1, 2, 3, 4] {
            let complete = candidates.count / size
            let queued = candidates.count % size
            let charCap = 240     // Proposed max UTF-8 bytes of unresolved instruction per observation.
            let promptCap = 480   // Proposed bytes for the stable task instructions and previous brief.
            let refs = try encoder.encode(Array(repeating: UUID(), count: size)).count
            let upperBytes = promptCap + refs + charCap * size
            print("synthetic trialBatchSize=\(size) eligible=\(candidates.count) callsAtIdle=\(complete) deferred=\(queued) estimatedInputBytesPerFullBatch=\(upperBytes)")
        }
        print("synthetic exportedBytes=\(bytes.count)\n\(imported.describe())")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGATO_STYLE_DIAGNOSTICS"] != nil,
                   "Set LEGATO_STYLE_DIAGNOSTICS to a local metadata export to replay collected evidence."))
    func collectedDiagnostics() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEGATO_STYLE_DIAGNOSTICS"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let replay = try StyleReplay.read(data)
        print("Collected diagnostic coverage (local metadata only; preference accuracy requires independent labels)\n\(replay.describe())")
    }
}
