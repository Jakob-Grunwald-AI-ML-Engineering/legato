import Foundation

/// One FIFO for inbox requests and every platform-specific command ingress.
/// Handlers may suspend; the pump never admits a second handler before the first settles.
@MainActor public final class DevHarness {
    public typealias Handler = @MainActor (BridgeCommand) async throws -> [String: Any]?
    public static let pollInterval: Duration = .milliseconds(500)
    public let transport: InboxTransport
    private var handlers: [String: Handler] = [:]
    private var seenIDs: [String] = []
    private var pumping = false
    private var polling: Task<Void, Never>?

    public init(root: URL) {
        transport = InboxTransport(root: root)
        register("ping") { _ in ["pong": true] }
        register("commands") { [weak self] _ in ["commands": self?.commandNames ?? []] }
    }

    private var operations: [String: (command: String, task: Task<Void, Never>)] = [:]
    public var pendingOperationCount: Int { operations.count }
    public var pendingOperationCommands: [String] { operations.values.map(\.command) }

    /// Reserve synchronously in the handler FIFO; owned work settles outside it so control requests can run.
    public func acceptOperation(_ command: BridgeCommand, reserve: () throws -> Void = {},
                                operation: @escaping @MainActor () async throws -> [String: Any]) throws -> [String: Any] {
        try reserve()
        let task = Task { @MainActor in
            var fields: [String: Any]
            do {
                try Task.checkCancellation()
                fields = try await operation()
                try Task.checkCancellation()
            } catch is CancellationError { fields = ["outcome": "cancelled"] }
            catch { fields = ["outcome": "failed", "message": String(describing: error)] }
            operations[command.id] = nil
            fields["command"] = command.command
            emit(id: command.id, event: "control.done", fields)
        }
        operations[command.id] = (command.command, task)
        return ["accepted": true, "waitFor": "control.done"]
    }
    @discardableResult
    public func cancelOperations(commands: Set<String>) -> [Task<Void, Never>] {
        let current = operations.values.filter { commands.contains($0.command) }.map(\.task)
        for task in current { task.cancel() }
        return current
    }
    public func waitForOperations() async {
        let current = operations.values.map(\.task)
        for task in current { await task.value }
    }

    public var commandNames: [String] { handlers.keys.sorted() }
    public func register(_ name: String, handler: @escaping Handler) { handlers[name] = handler }
    public func emit(id: String, event: String, _ fields: [String: Any] = [:]) { transport.emit(id: id, event: event, fields) }

    public func start() {
        guard polling == nil else { return }
        let dropped = transport.prepare()
        emit(id: "-", event: "started", ["dropped": dropped, "pid": ProcessInfo.processInfo.processIdentifier,
                                          "generation": UUID().uuidString, "commands": commandNames])
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.drain()
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
            }
        }
    }

    /// Stops inbox polling. Already accepted work settles in the same pump, including across a restart.
    public func stop() { polling?.cancel(); polling = nil }

    public func drain() async {
        // Take the complete sorted snapshot before the first suspension. Another drain cannot consume it.
        let commands = transport.takeCommands()
        guard !commands.isEmpty else { return }
        await withCheckedContinuation { continuation in
            for command in commands.dropLast() { append(command, completion: nil) }
            append(commands[commands.count - 1], completion: continuation)
        }
    }

    public func execute(_ command: BridgeCommand) async {
        await withCheckedContinuation { append(command, completion: $0) }
    }

    private func append(_ command: BridgeCommand, completion: CheckedContinuation<Void, Never>?) {
        queue.append(Entry(command: command, completion: completion))
        guard !pumping else { return }
        pumping = true
        Task { @MainActor in
            while !queue.isEmpty {
                let item = queue.removeFirst()
                await run(item.command)
                item.completion?.resume()
            }
            pumping = false
        }
    }

    private struct Entry { let command: BridgeCommand; let completion: CheckedContinuation<Void, Never>? }
    private var queue: [Entry] = []
    private func run(_ command: BridgeCommand) async {
        if seenIDs.contains(command.id) {
            emit(id: command.id, event: "duplicate", ["command": command.command])
            return
        }
        seenIDs.append(command.id)
        if seenIDs.count > 500 { seenIDs.removeFirst(100) }
        emit(id: command.id, event: "received", ["command": command.command])
        guard let handler = handlers[command.command] else {
            emit(id: command.id, event: "error", ["message": "unknown command \(command.command)"])
            return
        }
        do {
            var fields = try await handler(command) ?? [:]
            fields["command"] = command.command
            emit(id: command.id, event: "done", fields)
        } catch {
            emit(id: command.id, event: "error", ["command": command.command, "message": String(describing: error)])
        }
    }
}
