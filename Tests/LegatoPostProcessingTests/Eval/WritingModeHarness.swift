import CryptoKit
import Foundation
import Synchronization

enum WritingModeSplit: String, Codable, Sendable { case dev, validation }

struct WritingModeEvalError: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ description: String) { self.description = description }
}

/// An explicit experiment with the existing product timeout setting, never a changed app default.
struct WritingModeDeadline: Codable, Sendable {
    let defaultSeconds: Double
    let configuredSeconds: Double?
    let appliedSeconds: Double
    let source: String

    init(defaultSeconds: Double, configured: String?) throws {
        self.defaultSeconds = defaultSeconds
        if let configured {
            guard let seconds = Double(configured), seconds.isFinite, (1...10).contains(seconds) else {
                throw WritingModeEvalError("LEGATO_WRITING_TIMEOUT_SECONDS must be a finite number between 1 and 10")
            }
            configuredSeconds = seconds
            appliedSeconds = seconds
            source = "explicit-user-setting"
        } else {
            configuredSeconds = nil
            appliedSeconds = defaultSeconds
            source = "backend-default"
        }
    }
}

/// Predeclared requirements, never a target sentence or a lexical similarity score.
struct WritingModeFixture: Codable, Sendable {
    var id: String
    var language: String
    var locale: String
    var mode: String
    var emoji: String
    var input: String
    var meaning: [String]
    var forbiddenAdditions: [String]
    var correction: String
    var review: [String]
    /// Each group is a regex disjunction for one objective anchor, not an output template.
    var required: [[String]]
    var forbidden: [String]
    var paragraphs: Bool
    var list: Bool
    var minEmoji: Int
    var maxEmoji: Int

    func validate() throws {
        guard !id.isEmpty, !input.isEmpty, !meaning.isEmpty, !forbiddenAdditions.isEmpty,
              !correction.isEmpty, !review.isEmpty,
              ["de", "en", "mixed"].contains(language),
              ["verbatim", "message", "markdown"].contains(mode),
              ["off", "subtle", "expressive"].contains(emoji),
              minEmoji >= 0, maxEmoji >= minEmoji,
              required.allSatisfy({ !$0.isEmpty }) else {
            throw WritingModeEvalError("Invalid fixture contract: \(id)")
        }
        for pattern in required.flatMap({ $0 }) + forbidden {
            _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }
}

enum WritingModeFixtures {
    static func load(_ split: WritingModeSplit) throws -> [WritingModeFixture] {
        guard let url = Bundle.module.url(forResource: split.rawValue, withExtension: "json", subdirectory: "Fixtures/cleanup-modes") else {
            throw WritingModeEvalError("Missing writing-mode fixtures: \(split)")
        }
        let fixtures = try JSONDecoder().decode([WritingModeFixture].self, from: Data(contentsOf: url))
        guard !fixtures.isEmpty, Set(fixtures.map(\.id)).count == fixtures.count else {
            throw WritingModeEvalError("Empty or duplicate fixture IDs")
        }
        for fixture in fixtures { try fixture.validate() }
        return fixtures
    }
}

enum WritingModeChecks {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func emojiCount(_ text: String) -> Int {
        text.filter { character in
            let scalars = character.unicodeScalars
            return scalars.contains { $0.properties.isEmojiPresentation }
                || (scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
                    && scalars.contains { $0.properties.isEmoji })
        }.count
    }

    static func failures(_ output: String, fixture: WritingModeFixture) -> [String] {
        var failures: [String] = []
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failures.append("empty") }
        for (index, alternatives) in fixture.required.enumerated() where !alternatives.contains(where: { matches($0, output) }) {
            failures.append("required-\(index)")
        }
        for (index, pattern) in fixture.forbidden.enumerated() where matches(pattern, output) { failures.append("forbidden-\(index)") }
        if fixture.paragraphs && !matches("\\n[ \\t]*\\n", output) { failures.append("paragraphs") }
        if fixture.list && !matches("(?m)^\\s*(?:[-*+] |[0-9]+[.)] )", output) { failures.append("list") }
        let count = emojiCount(output)
        if count < fixture.minEmoji { failures.append("emoji-minimum") }
        if count > fixture.maxEmoji { failures.append("emoji-maximum") }
        return failures
    }
}

struct WritingModeSummary: Codable, Sendable {
    var completed: Int = 0
    var unavailable: Int = 0
    var operationalFailures: Int = 0
    var objectiveFailures: Int = 0
    var objectiveSuccess: Bool { completed > 0 && unavailable == 0 && operationalFailures == 0 && objectiveFailures == 0 }
    // An automatic run never certifies the pending independent side-by-side review.
    var validatedQuality: Bool { false }

    enum CodingKeys: String, CodingKey {
        case completed, unavailable, operationalFailures, objectiveFailures, objectiveSuccess, validatedQuality, reviewStatus
    }
    init(completed: Int = 0, unavailable: Int = 0, operationalFailures: Int = 0, objectiveFailures: Int = 0) {
        self.completed = completed
        self.unavailable = unavailable
        self.operationalFailures = operationalFailures
        self.objectiveFailures = objectiveFailures
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        completed = try values.decode(Int.self, forKey: .completed)
        unavailable = try values.decode(Int.self, forKey: .unavailable)
        operationalFailures = try values.decode(Int.self, forKey: .operationalFailures)
        objectiveFailures = try values.decode(Int.self, forKey: .objectiveFailures)
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(completed, forKey: .completed)
        try values.encode(unavailable, forKey: .unavailable)
        try values.encode(operationalFailures, forKey: .operationalFailures)
        try values.encode(objectiveFailures, forKey: .objectiveFailures)
        try values.encode(objectiveSuccess, forKey: .objectiveSuccess)
        try values.encode(validatedQuality, forKey: .validatedQuality)
        try values.encode("pending independent semantic and naturalness review", forKey: .reviewStatus)
    }
}

func writingModeHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A timer resolves the waiter without awaiting an uncooperative native task, unlike a task-group race.
/// The caller retains the worker and must stop using that backend until settlement is established.
private final class WritingModeRace<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, any Error>?
        var waiter: CheckedContinuation<Result<Value, any Error>, Never>?
    }
    private let state = Mutex(State())
    func resolve(_ result: Result<Value, any Error>) {
        let waiter = state.withLock { state in
            guard state.result == nil else { return Optional<CheckedContinuation<Result<Value, any Error>, Never>>.none }
            state.result = result
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: result)
    }
    func value() async -> Result<Value, any Error> {
        await withCheckedContinuation { continuation in
            let result: Result<Value, any Error>? = state.withLock { state in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}

struct WritingModeBounded<Value: Sendable>: Sendable {
    let result: Result<Value, any Error>
    let worker: Task<Void, Never>
    let timedOut: Bool
}

func writingModeWaitForSettlement(worker: Task<Void, Never>, seconds: Double) async -> Bool {
    // Cleanup must observe the worker even when the production deadline cancelled its caller.
    // A detached observer does not inherit that cancellation; its own timer still bounds the wait.
    await Task.detached {
        let settlement = await writingModeBounded(seconds: seconds) { await worker.value; return true }
        return (try? settlement.result.get()) == true
    }.value
}

func writingModeBounded<Value: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> Value) async -> WritingModeBounded<Value> {
    let race = WritingModeRace<Value>()
    let worker = Task.detached {
        do { race.resolve(.success(try await operation())) }
        catch { race.resolve(.failure(error)) }
    }
    let timer = Task.detached {
        do {
            try await Task.sleep(for: .seconds(seconds))
            race.resolve(.failure(WritingModeEvalError("deadline-exceeded")))
        } catch { /* normal timer cancellation after completion */ }
    }
    let result = await withTaskCancellationHandler {
        await race.value()
    } onCancel: {
        worker.cancel()
        race.resolve(.failure(WritingModeEvalError("cancelled; settlement not established")))
    }
    timer.cancel()
    let timedOut: Bool
    if case .failure(let error) = result { timedOut = (error as? WritingModeEvalError)?.description == "deadline-exceeded" } else { timedOut = false }
    if timedOut { worker.cancel() }
    return .init(result: result, worker: worker, timedOut: timedOut)
}
