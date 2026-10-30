import Foundation
import Testing
@testable import LegatoDevHarness

@Suite(.timeLimit(.minutes(1))) @MainActor struct HarnessTests {
    @Test func wireDefaultsAndMalformedInput() throws {
        let command = try #require(BridgeCommand.decode(Data(#"{"id":"a","command":"ping"}"#.utf8)))
        #expect(command == BridgeCommand(id: "a", command: "ping"))
        #expect(BridgeCommand.decode(Data(#"{"command":"ping"}"#.utf8)) == nil)
        #expect(BridgeCommand.decode(Data(#"{"id":"a","command":"ping","args":3}"#.utf8)) == nil)
    }

    @Test func pingProducesMatchingTerminalEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legato-harness-task2-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = DevHarness(root: root)
        await harness.execute(BridgeCommand(id: "request-1", command: "ping"))
        let text = (try? String(contentsOf: harness.transport.logURL, encoding: .utf8)) ?? ""
        #expect(text.contains(#""id":"request-1""#))
        #expect(text.contains(#""event":"done""#))
        #expect(text.contains(#""pong":true"#))
    }

    @Test func hiddenAskIsNotShownUntilPresentation() {
        var events: [String] = []
        let messages = DebugMessages { _, event, _ in events.append(event) }
        messages.ask(id: "question", text: "Ready?", choices: ["Yes"], timeout: 10)
        #expect(events.isEmpty)
    }

    @Test func directCommandsAndInboxShareOneSuspendingPump() async throws {
        let rig = HarnessRig()
        defer { rig.clean() }
        let entered = Signal(), release = Signal(), submitted = Signal()
        var order: [String] = []
        rig.harness.register("hold") { _ in
            order.append("hold-start")
            entered.open()
            await release.wait()
            order.append("hold-end")
            return nil
        }
        rig.harness.register("next") { _ in order.append("next"); return nil }
        let first = Task { await rig.harness.execute(BridgeCommand(id: "1", command: "hold")) }
        await entered.wait()
        try rig.write("2", command: "next")
        let second = Task { submitted.open(); await rig.harness.drain() }
        await submitted.wait()
        release.open()
        await first.value
        await second.value
        #expect(order == ["hold-start", "hold-end", "next"])
        #expect(try rig.events().filter { $0["event"] as? String == "done" }.compactMap { $0["id"] as? String } == ["1", "2"])
    }

    @Test func retriesAndBoundedDeduplication() async throws {
        let rig = HarnessRig()
        defer { rig.clean() }
        var runs = 0
        rig.harness.register("count") { _ in runs += 1; return nil }
        await rig.harness.execute(BridgeCommand(id: "same", command: "count"))
        await rig.harness.execute(BridgeCommand(id: "same", command: "count"))
        #expect(runs == 1)
        #expect(try rig.events().last?["event"] as? String == "duplicate")
        for i in 0..<500 { await rig.harness.execute(BridgeCommand(id: "later-\(i)", command: "count")) }
        await rig.harness.execute(BridgeCommand(id: "same", command: "count"))
        #expect(runs == 502)
    }

    @Test func unknownAndThrowingCommandsProduceErrors() async throws {
        let rig = HarnessRig()
        defer { rig.clean() }
        enum Failure: Error { case expected }
        rig.harness.register("fail") { _ in throw Failure.expected }
        await rig.harness.execute(BridgeCommand(id: "unknown", command: "not-registered"))
        await rig.harness.execute(BridgeCommand(id: "failed", command: "fail"))
        let errors = try rig.events().filter { $0["event"] as? String == "error" }
        #expect(errors.compactMap { $0["id"] as? String } == ["unknown", "failed"])
        #expect(errors.first?["message"] as? String == "unknown command not-registered")
    }

    @Test func inboxIsSortedAndBadFilesGetThreePolls() async throws {
        let rig = HarnessRig()
        defer { rig.clean() }
        var ids: [String] = []
        rig.harness.register("record") { command in ids.append(command.id); return nil }
        try rig.write("b", command: "record")
        try rig.write("a", command: "record")
        let bad = rig.harness.transport.inbox.appendingPathComponent("bad.json")
        try Data("partial".utf8).write(to: bad)
        await rig.harness.drain()
        #expect(ids == ["a", "b"])
        #expect(FileManager.default.fileExists(atPath: bad.path))
        await rig.harness.drain()
        #expect(FileManager.default.fileExists(atPath: bad.path))
        await rig.harness.drain()
        #expect(!FileManager.default.fileExists(atPath: bad.path))
        #expect(try rig.events().last?["message"] as? String == "undecodable command file")
    }

    @Test func startupDropsStaleFilesAndPublishesFreshGeneration() async throws {
        let rig = HarnessRig()
        defer { rig.clean() }
        try rig.write("old", command: "ping")
        try FileManager.default.createDirectory(at: rig.harness.transport.root, withIntermediateDirectories: true)
        let oldLog = (0..<2001).map { "{\"old\":\($0)}" }.joined(separator: "\n") + "\n"
        try oldLog.write(to: rig.harness.transport.logURL, atomically: true, encoding: .utf8)
        rig.harness.start()
        rig.harness.stop()
        let lines = try rig.events()
        let started = try #require(lines.last)
        #expect(lines.count == 1001)
        #expect(started["event"] as? String == "started")
        #expect(started["dropped"] as? Int == 1)
        let generation = try #require(started["generation"] as? String)
        #expect(UUID(uuidString: generation) != nil)
        #expect(!FileManager.default.fileExists(atPath: rig.harness.transport.inbox.appendingPathComponent("old.json").path))
        rig.harness.start()
        rig.harness.stop()
        #expect(try rig.events().last?["generation"] as? String != generation)
    }

    @Test func acceptedLongWorkDoesNotHoldCommandPump() async throws {
        let rig = HarnessRig()
        defer { rig.clean() }
        let release = Signal()
        var work: Task<Void, Never>?
        rig.harness.register("long") { _ in
            work = Task { await release.wait(); rig.harness.emit(id: "probe", event: "probe.done") }
            return ["accepted": true]
        }
        await rig.harness.execute(BridgeCommand(id: "probe", command: "long"))
        await rig.harness.execute(BridgeCommand(id: "ping", command: "ping"))
        #expect(try rig.events().last?["id"] as? String == "ping")
        #expect(try rig.events().contains { $0["event"] as? String == "probe.done" } == false)
        release.open()
        await work?.value
        #expect(try rig.events().last?["event"] as? String == "probe.done")
    }

    @Test func ownedAcceptanceReservesBeforeReturningAndLeavesThePumpResponsive() async throws {
        let rig = HarnessRig()
        defer { rig.clean() }
        let release = Signal()
        var reserved = false
        rig.harness.register("long-owned") { command in
            try rig.harness.acceptOperation(command, reserve: { reserved = true }) {
                await release.wait()
                return ["outcome": "ok"]
            }
        }
        await rig.harness.execute(BridgeCommand(id: "owned", command: "long-owned"))
        #expect(reserved)
        #expect(rig.harness.pendingOperationCount == 1)
        await rig.harness.execute(BridgeCommand(id: "responsive", command: "ping"))
        #expect(try rig.events().last?["id"] as? String == "responsive")
        #expect(try !rig.events().contains { $0["event"] as? String == "control.done" })
        release.open()
        await rig.harness.waitForOperations()
        #expect(rig.harness.pendingOperationCount == 0)
        #expect(try rig.events().last?["event"] as? String == "control.done")
        #expect(try rig.events().last?["id"] as? String == "owned")
    }

    @Test func cancellationBeforeOwnedWorkStartsNeverRunsTheBody() async throws {
        let rig = HarnessRig()
        defer { rig.clean() }
        var ran = false
        _ = try rig.harness.acceptOperation(BridgeCommand(id: "cancelled", command: "toggle")) {
            ran = true
            return ["outcome": "ok"]
        }
        rig.harness.cancelOperations(commands: ["toggle"])
        await rig.harness.waitForOperations()
        #expect(!ran)
        #expect(try rig.events().last?["outcome"] as? String == "cancelled")
    }

    @Test func messagePresentationStartsOnlyFrontTimeoutAndClearReplies() async {
        let timer = TimerSignal(), replied = Signal()
        var events: [(String, String, String?)] = []
        let messages = DebugMessages(emit: { id, event, fields in events.append((id, event, fields["choice"] as? String)); if fields["choice"] as? String == "timeout" { replied.open() } }, sleep: { try await timer.sleep($0) })
        messages.say(id: "notice", text: "Read this")
        messages.ask(id: "first", text: "Ready?", choices: ["Yes"], timeout: 12)
        messages.ask(id: "second", text: "Continue?", choices: ["OK"], timeout: 5)
        messages.presented(id: "first")
        #expect(events.isEmpty)
        messages.reply(id: "notice", choice: "OK")
        #expect(events.map { $0.1 } == ["dismissed"])
        messages.presented(id: "first")
        await timer.entered.wait()
        #expect(timer.durations == [.seconds(12)])
        #expect(events.map { $0.1 } == ["dismissed", "shown"])
        timer.release.open()
        await timer.finished.wait()
        // Join the production timer's reply signal rather than guessing when its continuation runs.
        await replied.wait()
        #expect(events.last?.2 == "timeout")
        #expect(messages.current?.id == "second")
        messages.setStatus("Working")
        messages.setBlocking(true)
        messages.clear()
        #expect(events.last?.0 == "second")
        #expect(events.last?.2 == "cleared")
        #expect(messages.queue.isEmpty)
        #expect(messages.status == nil)
        #expect(!messages.blocking)
    }

    @Test func parserPreservesArgumentsAndRejectsInvalidTimeouts() throws {
        let parsed = try #require(DebugMessages.parse(["Line 1\nLine 2", "--sound", "Yes", "--timeout", "4.5", "No"], takesChoices: true))
        #expect(parsed.text == "Line 1\nLine 2")
        #expect(parsed.choices == ["Yes", "No"])
        #expect(parsed.timeout == 4.5)
        #expect(parsed.sound)
        #expect(DebugMessages.parse(["Question"], takesChoices: true) == nil)
        #expect(DebugMessages.parse(["Question", "Yes", "--timeout", "0"], takesChoices: true) == nil)
        #expect(DebugMessages.parse(["Question", "Yes", "--timeout"], takesChoices: true) == nil)
    }
}

@MainActor private final class Signal {
    private var opened = false
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    func open() {
        opened = true
        let pending = waiters.values
        waiters = [:]
        for waiter in pending { waiter.yield(()); waiter.finish() }
    }
    func wait() async {
        guard !opened, !Task.isCancelled else { return }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters[id] = continuation
        defer { waiters[id] = nil }
        // AsyncStream's iterator finishes when its waiting task is cancelled.
        for await _ in stream { return }
    }
}

@MainActor private final class TimerSignal {
    let entered = Signal(), release = Signal(), finished = Signal()
    var durations: [Duration] = []
    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        entered.open()
        await release.wait()
        finished.open()
        try Task.checkCancellation()
    }
}

@MainActor private final class HarnessRig {
    let harness: DevHarness
    init() { harness = DevHarness(root: FileManager.default.temporaryDirectory.appendingPathComponent("legato-harness-task2-\(UUID())")) }
    func clean() { harness.stop(); try? FileManager.default.removeItem(at: harness.transport.root) }
    func write(_ id: String, command: String) throws {
        try FileManager.default.createDirectory(at: harness.transport.inbox, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["id": id, "command": command]).write(to: harness.transport.inbox.appendingPathComponent("\(id).json"))
    }
    func events() throws -> [[String: Any]] {
        let text = try String(contentsOf: harness.transport.logURL, encoding: .utf8)
        return try text.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
}
