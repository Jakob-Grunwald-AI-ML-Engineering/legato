import Darwin
import Foundation
import Synchronization
import Testing
import LegatoCore
@testable import LegatoClaude

@Suite struct MessagesStreamTransportTests {
    @Test func realHTTPStreamPreservesBlankFramesAndUnicode() async throws {
        let server = try SSEHTTPServer(body: "event: content_block_delta\r\ndata: Grüß 🌊\r\ndata: second line\r\n\r\nevent: message_stop\r\ndata: {}\r\n\r\n")
        let transport = MessagesStream(keyStore: InMemoryAPIKeyStore(apiKey: "fixture"), endpoint: server.url)
        var events: [SSEEvent] = []
        // Exceed the fixture's read buffer so headers/body arrive across reads.
        let request = Data(("{\"input\":\"" + String(repeating: "a", count: 32768) + "\"}").utf8)
        for try await event in transport.stream(request: request) { events.append(event) }
        #expect(events == [SSEEvent(event: "content_block_delta", data: "Grüß 🌊\nsecond line"), SSEEvent(event: "message_stop", data: "{}")])
        #expect(server.requestBody == request)
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
    private let receivedRequest = Mutex(Data())
    var requestBody: Data {
        receivedRequest.withLock { request in
            guard let boundary = request.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
            return Data(request[boundary.upperBound...])
        }
    }
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
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 5000) > 0 else { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            var request = Data()
            // Closing with unread request bytes can reset TCP instead of delivering the SSE response.
            while true {
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { return }
                request.append(contentsOf: buffer.prefix(count))
                guard request.count <= 1_048_576 else { return }
                guard let boundary = request.range(of: Data("\r\n\r\n".utf8)) else { continue }
                let headers = String(decoding: request[..<boundary.lowerBound], as: UTF8.self)
                guard let lengthHeader = headers.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let bodyLength = Int(lengthHeader.dropFirst(15).trimmingCharacters(in: .whitespaces)),
                      (0...1_048_576).contains(bodyLength) else { return }
                if request.count >= boundary.upperBound + bodyLength { break }
            }
            self.receivedRequest.withLock { $0 = request }
            for var byte in response {
                guard send(client, &byte, 1, 0) == 1 else { return }
            }
            _ = shutdown(client, SHUT_WR)
        }
    }
}
