import Foundation
import LegatoCore

/// Offline research only. Each phone or Mac has its own evidence; a shared take identifier does not imply sync.
typealias StyleEvent = StyleDiagnosticEvent

struct StyleReplay {
    struct Take: Hashable {
        let platform: StyleEvent.Platform
        let id: UUID
    }

    struct Observations {
        var addedByUser = 0
        var addedByAnyone = 0
        var scopedAdds = 0
        var ambiguousRequest = false
        var ambiguousHost = false
        var undone = false
        var deleted = false
    }

    enum InputError: Error, CustomStringConvertible {
        case malformed(line: Int), unsupported(line: Int), conflictingCopy(line: Int), empty
        var description: String {
            switch self {
            case .malformed(let line): "Invalid style diagnostic at line \(line)."
            case .unsupported(let line): "Unsupported style diagnostic version at line \(line)."
            case .conflictingCopy(let line): "Conflicting copy of a diagnostic event at line \(line)."
            case .empty: "No style diagnostic events in input."
            }
        }
    }

    private(set) var takes: [Take: Observations] = [:]
    private var events: [UUID: StyleEvent] = [:]
    private(set) var duplicates = 0
    private(set) var counts: [String: Int] = [:]
    private(set) var contexts: [String: Int] = [:]
    private(set) var instructions: [String: Int] = [:]
    private(set) var platforms: [String: Int] = [:]
    enum Decision: String { case cue, insufficientTakes, explicitInstruction, unknownScope, unknownMode, nonSendMode }
    private(set) var shadowDecisions: [String: Int] = [:]
    private var modes: [String: Int] = [:]
    private var requestContexts: [String: Int] = [:]
    private var requestInstructions: [String: Int] = [:]
    private var additions: [String: Int] = [:]
    private var removals: [String: Int] = [:]

    @discardableResult
    mutating func observe(_ event: StyleEvent, line: Int) throws -> Bool {
        if let old = events[event.eventID] {
            // History upserts and keyboard appearances can both acknowledge the same stable finalization.
            let repeatedFinalization = old.action == .finalized && event.action == .finalized &&
                old.takeID == event.takeID && old.platform == event.platform && old.context == event.context &&
                old.emojiAdded == event.emojiAdded && old.emojiRemoved == event.emojiRemoved && old.instruction == event.instruction &&
                old.mode == event.mode && old.requestID == event.requestID
            guard old == event || repeatedFinalization else { throw InputError.conflictingCopy(line: line) }
            duplicates += 1
            return false
        }
        events[event.eventID] = event
        counts[event.action.rawValue, default: 0] += 1
        contexts[event.context.rawValue, default: 0] += 1
        instructions[event.instruction.rawValue, default: 0] += 1
        platforms[event.platform.rawValue, default: 0] += 1
        if event.emojiAdded > 0 { additions[event.action.rawValue, default: 0] += 1 }
        if event.emojiRemoved > 0 { removals[event.action.rawValue, default: 0] += 1 }
        let key = Take(platform: event.platform, id: event.takeID)
        if event.action == .request {
            let decision = shadowDecision(at: event)
            shadowDecisions[decision.rawValue, default: 0] += 1
            modes[event.mode?.rawValue ?? "unknown", default: 0] += 1
            requestContexts[event.context.rawValue, default: 0] += 1
            requestInstructions[event.instruction.rawValue, default: 0] += 1
        }
        var observations = takes[key, default: .init()]
        let delta = event.emojiAdded - event.emojiRemoved
        func net(_ prior: Int) throws -> Int {
            let (sum, overflow) = prior.addingReportingOverflow(delta)
            guard !overflow else { throw InputError.malformed(line: line) }
            return sum
        }
        switch event.action {
        case .deleted:
            observations = .init()
            observations.deleted = true
        case .undo:
            // There is no target operation ID. Abstain on this take even if its earlier additions appeared deliberate.
            observations.undone = true
        case .typed, .suggestion:
            observations.addedByUser = try net(observations.addedByUser)
            if event.context == .sendField { observations.scopedAdds = try net(observations.scopedAdds) }
        case .hostEdit:
            observations.ambiguousHost = observations.ambiguousHost || event.emojiAdded != 0 || event.emojiRemoved != 0
        case .magic:
            if event.instruction == .other && (event.emojiAdded > 0 || event.emojiRemoved > 0) {
                observations.ambiguousRequest = true
            }
        default:
            break
        }
        switch event.action {
        case .typed, .suggestion, .hostEdit, .magic, .cleanup:
            observations.addedByAnyone = try net(observations.addedByAnyone)
        default:
            break
        }
        takes[key] = observations
        return true
    }

    func shadowDecision(at event: StyleEvent) -> Decision {
        guard let mode = event.mode else { return .unknownMode }
        guard mode == .send else { return .nonSendMode }
        guard event.instruction == .none else { return .explicitInstruction }
        guard event.context == .sendField else { return .unknownScope }
        let prior = active(on: event.platform, excluding: event.takeID)
        return prior.filter { $0.scopedAdds > 0 }.count >= 2 ? .cue : .insufficientTakes
    }

    func active(on platform: StyleEvent.Platform, excluding take: UUID? = nil) -> [Observations] {
        takes.compactMap { key, value in
            key.platform == platform && key.id != take && !value.deleted && !value.undone ? value : nil
        }
    }

    /// Read exported JSONL in timestamp order, preserving the file's order on ties (rotation writes oldest first).
    static func read(_ data: Data) throws -> Self {
        struct Version: Decodable { let v: Int }
        let decoder = JSONDecoder()
        var inputs: [(line: Int, event: StyleEvent)] = []
        for (offset, bytes) in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            if bytes.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
            let line = offset + 1
            guard let version = try? decoder.decode(Version.self, from: bytes) else { throw InputError.malformed(line: line) }
            guard version.v == 1 else { throw InputError.unsupported(line: line) }
            guard let event = try? decoder.decode(StyleEvent.self, from: bytes), event.emojiAdded >= 0, event.emojiRemoved >= 0 else {
                throw InputError.malformed(line: line)
            }
            inputs.append((line, event))
        }
        guard !inputs.isEmpty else { throw InputError.empty }
        inputs.sort { ($0.event.atMs, $0.line) < ($1.event.atMs, $1.line) }
        var replay = Self()
        for input in inputs { try replay.observe(input.event, line: input.line) }
        return replay
    }

    /// Sizes of hypothetical queues after an idle boundary. Only an ambiguous Magic instruction could
    /// be resolved by later classifying the instruction. A missing host actor cannot be reconstructed this way.
    func reviewCandidates(on platform: StyleEvent.Platform) -> [UUID] {
        takes.filter { key, value in key.platform == platform && !value.deleted && !value.undone && value.ambiguousRequest }
            .map { $0.key.id }
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// These are grouped workload counts after retractions. The same take can have both kinds of uncertainty.
    func describe() -> String {
        func table(_ counts: [String: Int]) -> String {
            counts.keys.sorted().map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: " ")
        }
        var modelLinks: [String: Int] = [:]
        for event in events.values where event.action == .cleanup || event.action == .magic {
            guard let id = event.requestID else { modelLinks["withoutLink", default: 0] += 1; continue }
            guard let request = events[id] else { modelLinks["requestOutsideExport", default: 0] += 1; continue }
            let valid = request.action == .request && request.takeID == event.takeID && request.platform == event.platform
            modelLinks[valid ? "matched" : "invalidLink", default: 0] += 1
        }
        var lines = ["uniqueEvents=\(events.count) duplicates=\(duplicates) observedTakes=\(takes.count)",
                     "observed events: \(table(counts))", "observed contexts: \(table(contexts))",
                     "observed instruction tags: \(table(instructions))", "observed platforms: \(table(platforms))",
                     "observations with emoji additions: \(table(additions))",
                     "observations with emoji removals: \(table(removals))",
                     "observed pre-request modes: \(table(modes))", "pre-request context: \(table(requestContexts))",
                     "pre-request instruction tags: \(table(requestInstructions))",
                     "hypothetical cue at pre-request: \(table(shadowDecisions))",
                     "model result to request: \(table(modelLinks))"]
        for platform in [StyleEvent.Platform.iOS, .macOS] {
            let active = active(on: platform)
            guard !active.isEmpty || platforms[platform.rawValue] != nil else { continue }
            lines.append("\(platform.rawValue) activeTakes=\(active.count) directNetAdds=\(active.filter { $0.addedByUser > 0 }.count) sendFieldDirectNetAdds=\(active.filter { $0.scopedAdds > 0 }.count) ambiguousMagicTakes=\(active.filter(\.ambiguousRequest).count) unattributedHostTakes=\(active.filter(\.ambiguousHost).count)")
        }
        return lines.joined(separator: "\n")
    }
}
