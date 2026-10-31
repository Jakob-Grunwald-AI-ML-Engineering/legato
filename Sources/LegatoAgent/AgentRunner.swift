import Foundation
import CryptoKit
import LegatoClaude
import LegatoRoom
import LegatoComposerDoc

private struct Conversation: Sendable {
    var messages: [JSONValue] = []
    var tokens = 0
    var lastTurn: Double = 0
    var seeded = false
}

/// One host-owned writer with quick, sentence, targeted, pause and final turns in one conversation.
public actor AgentRunner {
    private let room: Room
    private let client: any MessagesStreaming
    private var configuration: AgentConfiguration
    private let pauseDelay: Duration
    private var subscription: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var generation = UUID()
    private var pauseGeneration = UUID()
    private var policy = LiveAgentPolicy()
    private var conversation = Conversation()
    private var history: [Envelope] = []
    private var pendingContext: [Envelope] = []
    private var phase: WritingPhase?
    private var pauseDue = false
    private var acceptedSinceCompose = 0
    private var sentenceDue = false
    private var finalPending = false
    private var retiring = false
    private var stopped = false

    public init(room: Room, client: any MessagesStreaming, configuration: AgentConfiguration = .init(), pauseDelay: Duration = .seconds(1)) {
        self.room = room; self.client = client; self.configuration = configuration; self.pauseDelay = pauseDelay
    }
    public func start() async {
        guard subscription == nil else { return }; stopped = false
        let events = await room.subscribe(participant: .liveAgent, channels: [.asrRawTail, .asrTail, .asrSegment, .hint, .writingInstruction, .userIntent, .docOps, .session])
        subscription = Task { [weak self] in
            for await event in events { guard !Task.isCancelled else { break }; await self?.receive(event) }
        }
    }
    public func stop() {
        stopped = true; generation = UUID(); pauseGeneration = UUID()
        subscription?.cancel(); subscription = nil; pauseTask?.cancel(); writerTask?.cancel()
    }
    public func setMode(_ mode: ComposerMode) async throws {
        configuration.mode = mode
        _ = try await room.publish(channel: .userIntent, participant: .ui,
            payload: .object(["event": .string("mode.changed"), "mode": .string(mode.rawValue)]))
    }
    private func receive(_ event: Envelope) async {
        guard !stopped else { return }
        // Partials keep the quiet-period clock honest, including hidden targeted speech, but never enter model context.
        if event.channel == .asrRawTail || event.channel == .asrTail {
            if case .string(let text) = event.payload["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await speechActivity()
            }
            return
        }
        // Preserve the binder's single admission path for ordinary and explicitly targeted speech.
        if event.channel == .asrSegment { return }
        if event.channel == .session, event.payload["event"] == .string("debug.transcriber.frame") { return }
        if event.channel == .userIntent, event.payload["event"] == .string("tap") { return }
        history.append(event); pendingContext.append(event)
        if AgentAdmission.isAcceptedContent(event) {
            acceptedSinceCompose += 1
            let transaction = try? event.payload.decode(Transaction.self)
            let complete = transaction?.ops.contains { op in
                guard case .insertLines(_, let lines) = op,
                      let end = lines.last?.words.last?.text.last else { return false }
                return ".!?。！？".contains(end)
            } ?? false
            // Provider sentence punctuation is useful but not guaranteed. The segmenter
            // already bounds chunks at 25 words / 8 seconds, so two chunks guarantee progress.
            sentenceDue = sentenceDue || complete || acceptedSinceCompose >= 2
        }
        if AgentAdmission.isUserEdit(event) { sentenceDue = true }
        if event.channel == .session {
            if event.payload["event"] == .string("cancel.work") { stop(); return }
            if event.payload["event"] == .string("final.pass") {
                finalPending = true; pauseDue = false; pauseTask?.cancel()
            }
        }
        if case .string(let value) = event.payload["mode"], let mode = ComposerMode(rawValue: value) { configuration.mode = mode }
        if AgentAdmission.isAcceptedContent(event) || AgentAdmission.isUserEdit(event) || event.channel == .hint || event.channel == .writingInstruction || event.channel == .userIntent {
            if AgentAdmission.isAcceptedContent(event) || event.channel == .hint || event.channel == .writingInstruction || event.payload["event"] == .string("mode.changed") {
                await speechActivity()
            } else if phase == .pause { await cancelCurrentTurn() }
            let targets = Set(["line", "lineID"].compactMap { key -> String? in
                if case .string(let s) = event.payload[key] { return s }; return nil
            })
            if policy.enqueue(event, hintTargets: targets) { await cancelCurrentTurn() }
        }
        await schedule()
    }
    private func speechActivity() async {
        guard !finalPending, phase != .final else { return }
        pauseTask?.cancel(); pauseDue = false
        let token = UUID(); pauseGeneration = token
        if phase == .pause { await cancelCurrentTurn() }
        guard !stopped, token == pauseGeneration else { return }
        let delay = pauseDelay
        pauseTask = Task { [weak self] in
            do { try await Task.sleep(for: delay); await self?.pauseElapsed(token) } catch {}
        }
    }
    private func pauseElapsed(_ token: UUID) async {
        guard !stopped, token == pauseGeneration, !finalPending else { return }
        pauseDue = true; await schedule()
    }
    private func cancelCurrentTurn() async {
        guard phase != nil else { return }
        retiring = true
        let old = writerTask
        let canceledPhase = phase
        generation = UUID(); writerTask = nil; phase = nil; policy.finish()
        old?.cancel()
        await log(.liveAgent, ["event": .string("turn.cancel"), "phase": .string(canceledPhase?.rawValue ?? "unknown")])
        // Do not open the next request until the canceled stream has actually retired.
        await old?.value
        await log(.liveAgent, ["event": .string("pending.edit"), "lines": .array([])])
        await room.setAgentBusy(.liveAgent, busy: false)
        retiring = false
    }
    private func schedule() async {
        guard !stopped, !retiring, phase == nil else { return }
        let events: [Envelope]
        let next: WritingPhase
        if let pending = policy.begin() {
            events = pending
            if pending.contains(where: { $0.channel == .hint }) {
                next = .targeted
            } else if pending.contains(where: { $0.channel == .writingInstruction }) {
                next = .instruction
            } else if pauseDue && !finalPending {
                // Speech stopped while the previous quick request was still running.
                // Compose these queued notes now instead of paying for a redundant quick turn.
                next = .pause; pauseDue = false
            } else if sentenceDue || pending.contains(where: { $0.payload["event"] == .string("mode.changed") }) {
                next = .sentence
            } else {
                next = .quick
            }
        } else if finalPending, policy.beginMaintenance() {
            events = []; next = .final; finalPending = false
        } else if sentenceDue, policy.beginMaintenance() {
            events = []; next = .sentence
        } else if pauseDue, policy.beginMaintenance() {
            events = []; next = .pause; pauseDue = false
        } else { return }
        if next == .sentence || next == .pause || next == .final {
            acceptedSinceCompose = 0; sentenceDue = false
        }
        let token = UUID(); generation = token; phase = next
        await room.setAgentBusy(.liveAgent, busy: true)
        guard !stopped, generation == token else { return }
        writerTask = Task { [weak self] in await self?.run(events: events, phase: next, generation: token) }
    }
    public static func shouldReseed(tokens: Int, idle: Double) -> Bool { tokens > 50_000 || idle > 300 }
    public static func request(model: ModelChoice, system: String, messages: [JSONValue], live: Bool, mode: ComposerMode = .message) throws -> Data {
        let tools = try JSONValue.encoding(ToolExecutor.schemas(live: live, mode: mode))
        var fields: [String: JSONValue] = ["model": .string(model.rawValue), "max_tokens": .number(8192),
            "stream": .bool(true), "thinking": model.thinking, "system": .string(system), "messages": .array(messages),
            "tools": tools, "tool_choice": .object(["type": .string("auto")]), "cache_control": .object(["type": .string("ephemeral")])]
        if model != .haiku { fields["output_config"] = .object(["effort": .string("low")]) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(fields))
    }
    private func run(events: [Envelope], phase: WritingPhase, generation: UUID) async {
        let participant = Participant.liveAgent
        do {
            var conversation = self.conversation
            let now = ProcessInfo.processInfo.systemUptime
            let reseed = !conversation.seeded || Self.shouldReseed(tokens: conversation.tokens, idle: now - conversation.lastTurn)
            if reseed { conversation = Conversation() }
            let snapshot = await room.documentSnapshot
            let instructionSnapshot = events.last(where: { $0.channel == .writingInstruction })
                .flatMap { try? $0.payload["snapshot"]?.decode(DocumentSnapshot.self) }
            var allowedLineIDs: Set<String>? = phase == .instruction
                ? Set((instructionSnapshot ?? snapshot).lines.map(\.id))
                : (phase == .sentence ? Set(snapshot.lines.map(\.id)) : nil)
            let context = reseed ? history : pendingContext
            pendingContext = []
            let eventText = String(data: try JSONEncoder().encode(context), encoding: .utf8) ?? "[]"
            let activeEvents = String(data: try JSONEncoder().encode(events), encoding: .utf8) ?? "[]"
            let input = "Writing phase: \(phase.rawValue)\n\(PromptLayers.instruction(for: phase))\nCurrent mode: \(configuration.mode.rawValue)\nActive events for this turn:\n\(activeEvents)\nCurrent document:\n\(DocPresenter.present(snapshot))\nEvents:\n\(eventText)\n"
            await log(participant, ["event": .string("turn.phase"), "phase": .string(phase.rawValue)])
            conversation.messages.append(.object(["role": .string("user"), "content": .string(input)]))
            let turnMode = configuration.mode
            let terms = await configuration.vocabulary(snapshot.text)
            let system = PromptLayers.build(mode: turnMode, personal: configuration.personalPrompt, vocabulary: terms)
            let group = UUID().uuidString
            if reseed { await log(participant, ["event": .string("conversation.seed"), "system": .string(system), "tools": try .encoding(ToolExecutor.schemas(live: true, mode: turnMode))]) }
            // A turn may perform several tools and inspect their results before it finishes.
            for _ in 0..<24 {
                try Task.checkCancellation()
                let request = try Self.request(model: configuration.liveModel,
                    system: system, messages: conversation.messages, live: true, mode: turnMode)
                await log(participant, ["event": .string("request"), "request_hash": .string(SHA256.hash(data: request).map { String(format: "%02x", $0) }.joined()), "messages": .array(Array(conversation.messages.suffix(1)))])
                var blocks: [Int: JSONValue] = [:], partial: [Int: String] = [:]
                var usage: JSONValue = .null, first = true
                let started = ProcessInfo.processInfo.systemUptime
                for try await event in client.stream(request: request) {
                    try Task.checkCancellation()
                    await log(participant, ["event": .string("response.delta"), "type": .string(event.event), "data": .string(event.data)])
                    if first { first = false; await log(participant, ["event": .string("ttft"), "seconds": .number(ProcessInfo.processInfo.systemUptime - started)]) }
                    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else { continue }
                    if event.event == "error" { throw MessagesStreamError.provider(event.data) }
                    if let u = value["usage"] ?? value["message"]?["usage"], case .object(let fields) = u {
                        var combined: [String: JSONValue] = [:]
                        if case .object(let old) = usage { combined = old }
                        combined.merge(fields) { _, new in new }; usage = .object(combined)
                    }
                    guard case .number(let index) = value["index"], index.isFinite, index >= 0, index < 10000, index.rounded() == index else { continue }
                    let i = Int(index)
                    if let block = value["content_block"] { blocks[i] = block }
                    guard case .object(var block) = blocks[i], let delta = value["delta"] else { continue }
                    if case .string(let fragment) = delta["partial_json"] {
                        partial[i, default: ""] += fragment
                        let targets = PartialJSON.targets(in: partial[i]!)
                        policy.editing.formUnion(targets)
                        if !targets.isEmpty { await log(participant, ["event": .string("pending.edit"), "lines": .array(targets.sorted().map(JSONValue.string)), "group": .string(group)]) }
                    }
                    for key in ["text", "thinking", "signature"] {
                        if case .string(let fragment) = delta[key] {
                            let old: String; if case .string(let s) = block[key] { old = s } else { old = "" }
                            block[key] = .string(old + fragment)
                        }
                    }
                    blocks[i] = .object(block)
                }
                try Task.checkCancellation()
                for (i, json) in partial {
                    guard case .object(var block) = blocks[i] else { continue }
                    if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if block["input"] == nil { block["input"] = .object([:]) }
                    } else {
                        block["input"] = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
                    }
                    blocks[i] = .object(block)
                }
                let content = blocks.keys.sorted().compactMap { blocks[$0] }
                guard !content.isEmpty else { throw MessagesStreamError.incomplete }
                conversation.messages.append(.object(["role": .string("assistant"), "content": .array(content)]))
                await log(participant, ["event": .string("usage"), "usage": usage])
                if case .number(let tokens) = usage["input_tokens"] { conversation.tokens = Int(tokens) }
                // Include cache tokens: input_tokens excludes cached prefix tokens.
                for key in ["cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"] {
                    if case .number(let tokens) = usage[key] { conversation.tokens += Int(tokens) }
                }
                var results: [JSONValue] = []
                for block in content where block["type"] == .string("tool_use") {
                    try Task.checkCancellation()
                    guard case .string(let id) = block["id"], case .string(let name) = block["name"], let input = block["input"] else { throw MessagesStreamError.incomplete }
                    let result = await ToolExecutor(room: room).execute(name: name, input: input, groupID: group, live: true, phase: phase, allowedLineIDs: allowedLineIDs)
                    allowedLineIDs?.formUnion(result.createdLineIDs)
                    if result.requestCompose { sentenceDue = true }
                    if let mode = result.mode { configuration.mode = mode }
                    let value: JSONValue = .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(result.content), "is_error": .bool(result.isError)])
                    results.append(value); await log(participant, ["event": .string("tool.result"), "result": value])
                }
                if results.isEmpty { break }
                conversation.messages.append(.object(["role": .string("user"), "content": .array(results)]))
                // Semantic directives escalate once after this stream retires, without an
                // unnecessary acknowledgement request or a second concurrent writer.
                if phase == .quick && sentenceDue { break }
            }
            try Task.checkCancellation()
            conversation.lastTurn = ProcessInfo.processInfo.systemUptime; conversation.seeded = true
            self.conversation = conversation
        } catch is CancellationError {} catch {
            await log(participant, ["event": .string("error"), "message": .string(String(describing: error))])
        }
        guard generation == self.generation else { return }
        writerTask = nil; self.phase = nil; policy.finish()
        await log(participant, ["event": .string("pending.edit"), "lines": .array([])])
        if phase == .final {
            await room.setAgentBusy(participant, busy: false)
            try? await room.finishFinalPass()
        } else {
            await schedule()
            if !policy.running { await room.setAgentBusy(participant, busy: false) }
        }
    }
    private func log(_ participant: Participant, _ fields: [String: JSONValue]) async {
        _ = try? await room.publish(channel: .agentStatus, participant: participant, payload: .object(fields))
    }
}
