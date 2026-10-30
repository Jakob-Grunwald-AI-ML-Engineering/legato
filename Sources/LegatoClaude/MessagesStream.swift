import Foundation

public protocol MessagesStreaming: Sendable {
    func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error>
}
public enum MessagesStreamError: Error, Sendable { case missingKey, http(Int, String), provider(String), incomplete }

/// Separate from the legacy completion client: long-lived URLSession bytes with cancellation propagation.
public final class MessagesStream: MessagesStreaming, Sendable {
    private let keyStore: any APIKeyStore
    private let session: URLSession
    private let endpoint: URL
    public init(keyStore: any APIKeyStore, session: URLSession = .shared,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!) {
        self.keyStore = keyStore; self.session = session; self.endpoint = endpoint
    }
    public func stream(request: Data) -> AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = try keyStore.apiKey(), !key.isEmpty else { throw MessagesStreamError.missingKey }
                    var req = URLRequest(url: endpoint, timeoutInterval: 300)
                    req.httpMethod = "POST"; req.httpBody = request
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw MessagesStreamError.incomplete }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""; for try await line in bytes.lines { body += line; if body.count > 4096 { break } }
                        throw MessagesStreamError.http(http.statusCode, body)
                    }
                    var parser = SSEParser(), stopped = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = parser.consume(line: line) {
                            if event.event == "error" { throw MessagesStreamError.provider(event.data) }
                            continuation.yield(event)
                            if event.event == "message_stop" { stopped = true; break }
                        }
                    }
                    guard stopped else { throw MessagesStreamError.incomplete }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
