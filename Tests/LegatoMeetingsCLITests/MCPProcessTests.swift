#if os(macOS)
import Foundation
import Testing
@testable import LegatoMeetingsCLI

/// The built `legato` binary as a client runs it. `swift test` builds it next to the test bundle.
@Suite struct MCPProcessTests {
    private final class Marker {}

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private let arrived = DispatchSemaphore(value: 0)
        private var queue: [String] = []
        private(set) var all: [String] = []

        init(_ handle: FileHandle) {
            Thread.detachNewThread {
                var pending = Data()
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...newline)
                        self.lock.withLock { self.queue.append(line); self.all.append(line) }
                        self.arrived.signal()
                    }
                }
            }
        }

        func next(timeout: TimeInterval = 20) -> String? {
            guard arrived.wait(timeout: .now() + timeout) == .success else { return nil }
            return lock.withLock { queue.removeFirst() }
        }
    }

    @Test func exitsAfterInputEndsFollowingARealToolCall() async throws {
        let f = try await Fixture.make()
        defer { f.remove() }
        try Self.drive(root: f.root)
    }

    /// Blocking by nature (pipes, a child process), so it stays out of the async test.
    private static func drive(root: URL) throws {
        let binary = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("legato")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "swift test builds legato beside the test bundle")

        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp", "--root", root.path]
        let (input, output, errors) = (Pipe(), Pipe(), Pipe())
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let lines = Lines(output.fileHandleForReading)
        func send(_ line: String) { try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }

        // Boot.
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        let boot = lines.next().flatMap(JSONValue.parse)
        #expect(boot?["result"]?["serverInfo"]?["name"] == "legato", "boots and answers initialize")
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        // A real tool call, answered from the fixture.
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"invoice"}}}"#)
        let call = lines.next().flatMap(JSONValue.parse)
        guard case .array(let content)? = call?["result"]?["content"] else { Issue.record("no tool result: \(String(describing: call))"); return }
        #expect(call?["id"] == 2 && call?["result"]?["isError"] == false)
        #expect(content.first?["text"]?.stringValue?.contains("Weekly") == true, "the call finds the meeting")

        // Exit: the client closes stdin and the process ends by itself.
        try input.fileHandleForWriting.close()
        let ended = exited.wait(timeout: .now() + 10) == .success
        #expect(ended, "exits promptly once stdin is closed")
        if ended { #expect(process.terminationStatus == 0) }

        #expect(lines.all.allSatisfy { JSONValue.parse($0) != nil }, "stdout holds JSON-RPC only")
        #expect(lines.all.count == 2)
    }
}
#endif
