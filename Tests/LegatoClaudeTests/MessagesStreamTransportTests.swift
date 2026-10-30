import Darwin
import Foundation
import Testing
import LegatoCore
@testable import LegatoClaude

@Suite struct MessagesStreamTransportTests {
    @Test func realHTTPStreamPreservesBlankFramesAndUnicode() async throws {
        let server = try SSEHTTPServer(body: "event: content_block_delta\r\ndata: Grüß 🌊\r\ndata: second line\r\n\r\nevent: message_stop\r\ndata: {}\r\n\r\n")
        let transport = MessagesStream(keyStore: InMemoryAPIKeyStore(apiKey: "fixture"), endpoint: server.url)
        var events: [SSEEvent] = []
        for try await event in transport.stream(request: Data("{}".utf8)) { events.append(event) }
        #expect(events == [SSEEvent(event: "content_block_delta", data: "Grüß 🌊\nsecond line"), SSEEvent(event: "message_stop", data: "{}")])
    }
    @Test(arguments: [false, true]) func realHTTPStreamRetainsFailureGuards(providerError: Bool) async throws {
        let body = providerError ? "event: error\ndata: overloaded\n\n" : "event: content_block_delta\ndata: partial\n\n"
        let server = try SSEHTTPServer(body: body)
        let transport = MessagesStream(keyStore: InMemoryAPIKeyStore(apiKey: "fixture"), endpoint: server.url)
        var events: [SSEEvent] = []
        do {
            for try await event in transport.stream(request: Data("{}".utf8)) { events.append(event) }
            Issue.record("Expected the stream to fail")
        } catch let error as MessagesStreamError {
            switch error {
            case .provider(let message):
                #expect(providerError)
                #expect(message == "overloaded")
                #expect(events.isEmpty)
            case .incomplete:
                #expect(!providerError)
                #expect(events == [SSEEvent(event: "content_block_delta", data: "partial")])
            default: Issue.record("Unexpected stream error: \(error)")
            }
        }
    }
}

/// One real localhost HTTP response, sent byte by byte across the URLSession transport boundary.
private final class SSEHTTPServer: @unchecked Sendable {
    let url: URL
    init(body: String) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { close(listener); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/messages")!
        let response = Array(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
        DispatchQueue.global().async {
            defer { close(listener) }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            guard recv(client, &buffer, buffer.count, 0) > 0 else { return }
            for var byte in response {
                guard send(client, &byte, 1, 0) == 1 else { return }
            }
        }
    }
}
