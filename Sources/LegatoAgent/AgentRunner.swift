import Foundation
import CryptoKit
import LegatoClaude
import LegatoRoom

private struct Conversation: Sendable {
    var messages: [JSONValue] = []
    var tokens = 0
    var lastTurn: Double = 0
    var seeded = false
}

/// Host-owned orchestration. Attach before audio; Insert/cancel.work cancels both provider streams.
public actor AgentRunner {
    private let room: Room
    private let client: any MessagesStreaming
    private var configuration: AgentConfiguration
    private var subscription: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var restructureTask: Task<Void, Never>?
    private var liveGeneration = UUID()
    private var restructureGeneration = UUID()
    private var livePolicy = LiveAgentPolicy()
    private var restructurePolicy = RestructurePolicy()
    private var conversations: [Participant: Conversation] = [:]
    private var history: [Envelope] = []
    private var pendingContext: [Participant: [Envelope]] = [:]
    private var stopped = false

    public init(room: Room, client: any MessagesStreaming, configuration: AgentConfiguration = .init()) {
        self.room = room; self.client = client; self.configuration = configuration
    }
    public func start() async {
        guard subscription == nil else { return }; stopped = false
        let events = await room.subscribe(participant: .liveAgent, channels: [.asrSegment, .hint, .userIntent, .docOps, .session])
        subscription = Task { [weak self] in
            for await event in events { guard !Task.isCancelled else { break }; await self?.receive(event) }
        }
    }
    public func stop() {
        stopped = true; subscription?.cancel(); subscription = nil; pauseTask?.cancel()
        liveTask?.cancel(); restructureTask?.cancel()
    }
    public func setMode(_ mode: ComposerMode) async throws {
        configuration.mode = mode
        _ = try await room.publish(channel: .userIntent, participant: .ui,
            payload: .object(["event": .string("mode.changed"), "mode": .string(mode.rawValue)]))
    }
    private func receive(_ event: Envelope) async {
        guard !stopped else { return }
        history.append(event)
        pendingContext[.liveAgent, default: []].append(event)
        pendingContext[.restructureAgent, default: []].append(event)
        if event.channel == .session {
            if event.payload["event"] == .string("cancel.work") { stop(); return }
            if event.payload["event"] == .string("final.pass") { restructurePolicy.finalPass() }
        }
        if case .string(let value) = event.payload["mode"], let mode = ComposerMode(rawValue: value) { configuration.mode = mode }
        if event.channel == .asrSegment { return }
        if AgentAdmission.isAcceptedContent(event) {
            restructurePolicy.segment(at: event.tMono)
            pauseTask?.cancel()
            pauseTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(2500)); await self?.scheduleRestructure() } catch {}
            }
        }
        let targets = Set(["line", "lineID"].compactMap { key -> String? in
            if case .string(let s) = event.payload[key] { return s }; return nil
        })
        if livePolicy.enqueue(event, hintTargets: targets) {
            liveTask?.cancel(); liveGeneration = UUID(); livePolicy.finish()
        }
        await scheduleLive()
        await scheduleRestructure()
    }
    private func scheduleLive() async {
        guard !stopped, let events = livePolicy.begin() else { return }
        let generation = UUID(); liveGeneration = generation
        await room.setAgentBusy(.liveAgent, busy: true)
        liveTask = Task { [weak self] in await self?.run(participant: .liveAgent, events: events, final: false, generation: generation) }
    }
    private func scheduleRestructure() async {
        guard !stopped, let final = restructurePolicy.begin(at: ProcessInfo.processInfo.systemUptime) else { return }
        let generation = UUID(); restructureGeneration = generation
        await room.setAgentBusy(.restructureAgent, busy: true)
        restructureTask = Task { [weak self] in await self?.run(participant: .restructureAgent, events: [], final: final, generation: generation) }
    }
    public static func shouldReseed(tokens: Int, idle: Double) -> Bool { tokens > 50_000 || idle > 300 }
    public static func request(model: ModelChoice, system: String, messages: [JSONValue], live: Bool) throws -> Data {
        let tools = try JSONValue.encoding(ToolExecutor.schemas(live: live))
        var fields: [String: JSONValue] = ["model": .string(model.rawValue), "max_tokens": .number(8192),
            "stream": .bool(true), "thinking": model.thinking, "system": .string(system), "messages": .array(messages),
            "tools": tools, "tool_choice": .object(["type": .string("auto")]), "cache_control": .object(["type": .string("ephemeral")])]
        if model != .haiku { fields["output_config"] = .object(["effort": .string("low")]) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(fields))
    }
    private func run(participant: Participant, events: [Envelope], final: Bool, generation: UUID) async {
        let live = participant == .liveAgent
        do {
            var conversation = conversations[participant] ?? Conversation()
            let now = ProcessInfo.processInfo.systemUptime
            let reseed = !conversation.seeded || Self.shouldReseed(tokens: conversation.tokens, idle: now - conversation.lastTurn)
            if reseed { conversation = Conversation() }
            let snapshot = await room.documentSnapshot
            let context = reseed ? history : (pendingContext[participant] ?? events)
            pendingContext[participant] = []
            let eventText = String(data: try JSONEncoder().encode(context), encoding: .utf8) ?? "[]"
            let input = "Current mode: \(configuration.mode.rawValue)\nCurrent document:\n\(DocPresenter.present(snapshot))\nEvents:\n\(eventText)\n" + (final ? "Final whole-document pass: decide whether any changes help; finish when satisfied." : "Compose from the new events. " + (live ? "You are the live agent." : "You are the restructure agent."))
            conversation.messages.append(.object(["role": .string("user"), "content": .string(input)]))
            let terms = await configuration.vocabulary(snapshot.text)
            let system = PromptLayers.build(mode: configuration.mode, personal: configuration.personalPrompt, vocabulary: terms)
            let group = UUID().uuidString
            if reseed { await log(participant, ["event": .string("conversation.seed"), "system": .string(system), "tools": try .encoding(ToolExecutor.schemas(live: live))]) }
            // A turn may perform several tools and inspect their results before it finishes.
            for _ in 0..<24 {
                try Task.checkCancellation()
                let request = try Self.request(model: live ? configuration.liveModel : configuration.restructureModel,
                    system: system, messages: conversation.messages, live: live)
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
                        if live { livePolicy.editing.formUnion(targets) }
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
                for (i, json) in partial {
                    guard case .object(var block) = blocks[i] else { continue }
                    block["input"] = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)); blocks[i] = .object(block)
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
                    let result = await ToolExecutor(room: room).execute(name: name, input: input, groupID: group, live: live)
                    if let mode = result.mode { configuration.mode = mode }
                    if result.restructure { restructurePolicy.request(); await scheduleRestructure() }
                    let value: JSONValue = .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(result.content), "is_error": .bool(result.isError)])
                    results.append(value); await log(participant, ["event": .string("tool.result"), "result": value])
                }
                if results.isEmpty { break }
                conversation.messages.append(.object(["role": .string("user"), "content": .array(results)]))
            }
            try Task.checkCancellation()
            conversation.lastTurn = ProcessInfo.processInfo.systemUptime; conversation.seeded = true
            conversations[participant] = conversation
        } catch is CancellationError {} catch {
            await log(participant, ["event": .string("error"), "message": .string(String(describing: error))])
        }
        guard generation == (live ? liveGeneration : restructureGeneration) else { return }
        await log(participant, ["event": .string("pending.edit"), "lines": .array([])])
        if live {
            livePolicy.finish(); await scheduleLive()
            if !livePolicy.running { await room.setAgentBusy(participant, busy: false) }
        } else {
            restructurePolicy.finish()
            if final { try? await room.finishFinalPass() }
            else { await scheduleRestructure(); if !restructurePolicy.running { await room.setAgentBusy(participant, busy: false) } }
        }
    }
    private func log(_ participant: Participant, _ fields: [String: JSONValue]) async {
        _ = try? await room.publish(channel: .agentStatus, participant: participant, payload: .object(fields))
    }
}
