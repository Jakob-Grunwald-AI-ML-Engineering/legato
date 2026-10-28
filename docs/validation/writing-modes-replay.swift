import Foundation
import CryptoKit
import Synchronization
import LegatoCore
import LegatoPostProcessing

struct ReplayError: Error, CustomStringConvertible { let description: String }
func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
struct Request: Codable, Sendable {
    struct Example: Codable, Sendable { let user: String; let assistant: String }
    let instructions: String
    let examples: [Example]
    let userMessage: String
}
struct Call: Decodable, Sendable {
    let request: Request
    let promptSHA256: String
    let rawResponse: String?
    let rawResponseSHA256: String?
}
// Reuse the unchanged production-evaluation scorer. Its fixture loader is never invoked here.
extension Bundle { static var module: Bundle { Bundle.main } }
typealias Fixture = WritingModeFixture
struct Case: Decodable {
    let fixture: Fixture
    let calls: [Call]
    let deliveredOutput: String?
    let deliveredSHA256: String?
    let objectiveFailures: [String]
    let timedOut: Bool?
    let failed: Bool?
}
struct Run: Decodable { let cases: [Case] }
final class ReplayBackend: LLMBackend, Sendable {
    let id = "saved-raw-response-replay"
    let maxPromptCharacters: Int?
    let calls: [Call]
    let index = Mutex(0)
    init(calls: [Call], limit: Int?) { self.calls = calls; self.maxPromptCharacters = limit }
    var availability: LLMAvailability { get async { .available } }
    func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }
    func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        let next = index.withLock { let next = $0; $0 += 1; return next }
        guard next < calls.count else { throw ReplayError(description: "extra request") }
        let call = calls[next]
        guard instructions == call.request.instructions, prompt == call.request.userMessage,
              examples == call.request.examples.map({ LLMExample(user: $0.user, assistant: $0.assistant) })
        else { throw ReplayError(description: "request bytes changed at call \(next)") }
        guard let raw = call.rawResponse else { throw ReplayError(description: "no retained raw response") }
        return raw
    }
}
// Exact historical depth-scanner algorithm from the pre-fix source, for extraction-only comparison.
func oldExtract(_ reply: String) -> String {
    guard let open = reply.range(of: "<text>") else { return LLMCleanupStage.stripWrappers(reply) }
    let start = open.upperBound
    var cursor = start
    var depth = 1
    while cursor < reply.endIndex {
        let range = cursor..<reply.endIndex
        let nextOpen = reply.range(of: "<text>", range: range)
        let nextClose = reply.range(of: "</text>", range: range)
        if let nextOpen, nextClose == nil || nextOpen.lowerBound < nextClose!.lowerBound {
            depth += 1
            cursor = nextOpen.upperBound
        } else if let nextClose {
            depth -= 1
            if depth == 0 {
                return String(reply[start..<nextClose.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            cursor = nextClose.upperBound
        } else { break }
    }
    return String(reply[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
}
@main struct Replay {
    static func main() async throws {
        var rows: [[String: Any]] = []
        var requestChecks = 0
        var rawChecks = 0
        var extracted = 0
        var changedExtraction = 0
        var compared = 0
        var changedDelivery = 0
        var skipped = 0
        var scorerComparisons = 0
        var scorerChanges = 0
        var evidenceHashes: [String: String] = [:]
        for path in CommandLine.arguments.dropFirst() {
            let evidenceBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            evidenceHashes[path] = writingModeHash(evidenceBytes)
            let run = try JSONDecoder().decode(Run.self, from: evidenceBytes)
            let limit: Int? = path.contains("/coreml/") ? nil : 6000
            var fileCompared = 0
            var fileChanged = 0
            var fileSkipped = 0
            for row in run.cases {
                guard let style = CleanupStyle(rawValue: row.fixture.mode), let emoji = MessageEmojiStyle(rawValue: row.fixture.emoji)
                else { throw ReplayError(description: "unknown style") }
                let prompt = style.prompt(emoji: emoji)
                for call in row.calls {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let bytes = try encoder.encode(call.request)
                    guard sha(String(decoding: bytes, as: UTF8.self)) == call.promptSHA256 else {
                        throw ReplayError(description: "saved request hash mismatch")
                    }
                    requestChecks += 1
                    if let raw = call.rawResponse {
                        guard sha(raw) == call.rawResponseSHA256 else { throw ReplayError(description: "saved response hash mismatch") }
                        rawChecks += 1
                        extracted += 1
                        let prior = oldExtract(raw), fixed = prompt.extractText(raw)
                        if prior != fixed {
                            changedExtraction += 1
                            rows.append(["evidence": path, "id": row.fixture.id, "kind": "extraction-change",
                                         "before": prior, "after": fixed])
                        }
                    }
                }
                guard row.timedOut != true, row.failed != true, let original = row.deliveredOutput,
                      !row.calls.isEmpty, row.calls.allSatisfy({ $0.rawResponse != nil }) else {
                    skipped += 1; fileSkipped += 1
                    rows.append(["evidence": path, "id": row.fixture.id, "kind": "delivery-not-replayed",
                                 "reason": "original timeout/error or incomplete retained response sequence",
                                 "originalTimedOut": row.timedOut ?? false, "originalFailed": row.failed ?? false,
                                 "originalDeliverySHA256": row.deliveredSHA256 ?? "absent",
                                 "originalObjectiveFailures": row.objectiveFailures])
                    continue
                }
                guard sha(original) == row.deliveredSHA256 else { throw ReplayError(description: "saved delivery hash mismatch") }
                let backend = ReplayBackend(calls: row.calls, limit: limit)
                let stage = LLMCleanupStage(backend: backend, prompt: prompt, acceptance: .promptLed)
                let fixed = try await stage.process(row.fixture.input, locale: Locale(identifier: row.fixture.locale))
                guard backend.index.withLock({ $0 }) == row.calls.count else { throw ReplayError(description: "saved calls not fully consumed") }
                let scoredBefore = WritingModeChecks.failures(original, fixture: row.fixture)
                let scoredAfter = WritingModeChecks.failures(fixed, fixture: row.fixture)
                guard scoredBefore == row.objectiveFailures else { throw ReplayError(description: "historical scorer result mismatch") }
                scorerComparisons += 1
                if scoredBefore != scoredAfter { scorerChanges += 1 }
                compared += 1; fileCompared += 1
                var result: [String: Any] = ["evidence": path, "id": row.fixture.id, "kind": "delivery-replay",
                    "unchanged": fixed == original, "beforeSHA256": sha(original), "afterSHA256": sha(fixed), "calls": row.calls.count,
                    "beforeObjectiveFailures": scoredBefore, "afterObjectiveFailures": scoredAfter,
                    "scorerUnchanged": scoredBefore == scoredAfter]
                if fixed != original {
                    changedDelivery += 1; fileChanged += 1
                    result["before"] = original; result["after"] = fixed
                }
                rows.append(result)
            }
            print("\(path): deliveries=\(fileCompared), changed=\(fileChanged), operational-skips=\(fileSkipped)")
        }
        let report: [String: Any] = ["method": "saved raw responses only; exact requests and saved hashes verified; production LLMCleanupStage; no model instantiated; timeout/error deliveries excluded",
            "requestHashesVerified": requestChecks, "rawResponseHashesVerified": rawChecks,
            "extractionsCompared": extracted, "extractionsChanged": changedExtraction,
            "deliveriesCompared": compared, "deliveriesChanged": changedDelivery,
            "operationalDeliveriesSkipped": skipped, "scorerComparisons": scorerComparisons,
            "scorerChanges": scorerChanges, "evidenceSHA256": evidenceHashes, "rows": rows]
        for (path, expected) in evidenceHashes {
            guard writingModeHash(try Data(contentsOf: URL(fileURLWithPath: path))) == expected else {
                throw ReplayError(description: "evidence changed during replay")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/legato-pr73-replay-report.json"))
        print("TOTAL extraction=\(extracted), extraction-changes=\(changedExtraction), delivery=\(compared), delivery-changes=\(changedDelivery), operational-skips=\(skipped), scorer-comparisons=\(scorerComparisons), scorer-changes=\(scorerChanges)")
    }
}
