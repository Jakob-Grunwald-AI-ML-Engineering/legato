import Foundation
import LegatoCore

/// Fixed harbour-log workload. Prompts and replies never leave this measurement boundary.
@MainActor public struct SessionProbeMeasurements {
    private let now: @MainActor () -> TimeInterval
    private let sleep: @MainActor (Duration) async throws -> Void
    public init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.now = now; self.sleep = sleep
    }
    private let instructions = "You answer questions about the harbour log in at most eight words."
    private func sentences(_ range: ClosedRange<Int>) -> String {
        range.map { "\($0): The harbour master logged boat number \($0) arriving with a cargo of timber and rope." }.joined(separator: "\n")
    }

    public func run(_ descriptor: SessionProbeBackend, emit: @escaping @MainActor (SessionProbeMeasurement) -> Void) async throws {
        let context = sentences(1...40), request1 = "Which cargo did boat 3 bring?"
        let addition = "\n41: The ferry to the island leaves at noon.\n42: The pilot boat waits at the north pier."
        let request2 = "When does the ferry leave?"
        let (reply1, reply2) = try await withSession(descriptor.backend) { session in
            try await session.append(.instructions(instructions))
            try await session.append(.text(context))
            let first = try await turn(session, name: "1", chars: instructions.count + context.count + request1.count, request: request1, emit: emit)
            try await session.append(.text(addition))
            let second = try await turn(session, name: "2", chars: addition.count + request2.count, request: request2, emit: emit)
            return (first, second)
        }
        try await withSession(descriptor.backend) { session in
            try await session.append(.instructions(instructions))
            try await session.append(.example(.init(user: context + "\n\n" + request1, assistant: reply1)))
            try await session.append(.text(addition))
            _ = try await turn(session, name: "2.fresh", chars: instructions.count + context.count + reply1.count + addition.count,
                               request: request2, equalTo: reply2, emit: emit)
        }
        guard descriptor.measuresKickstart else { return }
        let head = instructions + "\n" + sentences(1...20), run = "[run 2]\n" + sentences(21...22)
        let request = "Which cargo did boat 22 bring?"
        try await withSession(descriptor.backend) { session in
            try await session.append(.instructions(head))
            let start = now()
            try await session.warm()
            let metrics = await (session as? any LLMSessionMetrics)?.lastWarmMetrics()
            emit(.init(turn: "kickstart.head", promptChars: head.count, wallMs: elapsed(start), metrics: metrics))
            try await sleep(.seconds(2)); try Task.checkCancellation()
            try await session.append(.text(run))
            _ = try await turn(session, name: "kickstart.warm", chars: run.count, request: request, emit: emit)
        }
        try await withSession(descriptor.backend) { session in
            try await session.append(.instructions(head))
            try await session.append(.text(run))
            try await session.warm()
            try await sleep(.seconds(2)); try Task.checkCancellation()
            _ = try await turn(session, name: "kickstart.warmPrefix", chars: run.count, request: request, emit: emit)
        }
        try await withSession(descriptor.backend) { session in
            try await session.append(.instructions(head))
            try await sleep(.seconds(2)); try Task.checkCancellation()
            try await session.append(.text(run))
            _ = try await turn(session, name: "kickstart.cold", chars: head.count + run.count, request: request, emit: emit)
        }
    }

    private func withSession<T>(_ backend: any LLMBackend, _ body: @MainActor (any LLMSession) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let session = try await backend.makeSession()
        do {
            try Task.checkCancellation()
            let result = try await body(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }
    private func turn(_ session: any LLMSession, name: String, chars: Int, request: String,
                      equalTo: String? = nil, emit: @MainActor (SessionProbeMeasurement) -> Void) async throws -> String {
        try Task.checkCancellation()
        let start = now(), reply = try await session.respond(to: request)
        try Task.checkCancellation()
        let metrics = await (session as? any LLMSessionMetrics)?.lastTurnMetrics()
        emit(.init(turn: name, promptChars: chars, wallMs: elapsed(start), metrics: metrics, replyEqual: equalTo.map { reply == $0 }))
        return reply
    }
    private func elapsed(_ start: TimeInterval) -> Int { Int(max(0, now() - start) * 1000) }
}
