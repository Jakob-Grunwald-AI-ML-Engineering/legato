import Foundation
import LegatoCore

/// Claude over the Messages API: an opt-in ``LLMBackend`` for summaries. It never runs on its own; the user
/// asks for it per meeting, because the transcript leaves the device.
///
/// | HTTP status | Handling |
/// |---|---|
/// | 401 | `.unavailable("Claude key rejected")` |
/// | 429, 529 | one retry after the `retry-after` header, then `.failed` |
/// | 400 "prompt is too long", 413 | `.contextTooLong` |
public struct ClaudeBackend: LLMBackend {
    public static let model = "claude-sonnet-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The longest wait a `retry-after` may ask for, in seconds.
    static let maxRetryAfter = 60

    public let id = "claude"
    public let maxPromptCharacters: Int? = 600_000

    private let keyStore: any APIKeyStore
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - session: the transport; tests pass one with a `URLProtocol` stub.
    ///   - sleep: waits out `retry-after`; tests record it instead.
    public init(
        keyStore: any APIKeyStore, session: URLSession = .shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.keyStore = keyStore
        self.session = session
        self.sleep = sleep
    }

    private static let noKey = "No Claude API key"

    public var availability: LLMAvailability {
        get async {
            guard let key = try? keyStore.apiKey(), !key.isEmpty else { return .unavailable(reason: Self.noKey) }
            return .available
        }
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        try await respond(instructions: instructions, examples: [], prompt: prompt)
    }

    public func respond(instructions: String, examples: [LLMExample], prompt: String) async throws -> String {
        guard let key = try? keyStore.apiKey(), !key.isEmpty else { throw LLMError.unavailable(reason: Self.noKey) }
        let request = try makeRequest(key: key, instructions: instructions, examples: examples, prompt: prompt)

        var retried = false
        while true {
            let (data, response) = try await send(request)
            switch response.statusCode {
            case 200..<300:
                return try Self.text(from: data)
            case 401:
                throw LLMError.unavailable(reason: "Claude key rejected")
            case 429, 529:
                guard !retried else { throw LLMError.failed("Claude is busy (HTTP \(response.statusCode))") }
                retried = true
                let seconds = response.value(forHTTPHeaderField: "retry-after").flatMap { Double($0) }.map { Int($0.rounded(.up)) } ?? 1
                try await sleep(.seconds(min(max(seconds, 0), Self.maxRetryAfter)))
            case 413:
                throw LLMError.contextTooLong
            default:
                let message = Self.errorMessage(from: data)
                if response.statusCode == 400, message.lowercased().contains("too long") { throw LLMError.contextTooLong }
                throw LLMError.failed("Claude HTTP \(response.statusCode): \(message)")
            }
        }
    }

    // MARK: Internals

    private func makeRequest(key: String, instructions: String, examples: [LLMExample], prompt: String) throws -> URLRequest {
        var messages: [[String: String]] = []
        for example in examples {
            messages.append(["role": "user", "content": example.user])
            messages.append(["role": "assistant", "content": example.assistant])
        }
        messages.append(["role": "user", "content": prompt])
        let body: [String: Any] = [
            "model": Self.model, "max_tokens": 4096, "system": instructions, "messages": messages,
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.failed("Claude: not an HTTP response") }
            return (data, http)
        } catch let error as LLMError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LLMError.failed("Claude request failed: \(error.localizedDescription)")
        }
    }

    private static func text(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.failed("Claude: unreadable response")
        }
        if json["stop_reason"] as? String == "refusal" { throw LLMError.guardrail }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any], let message = error["message"] as? String
        {
            return message
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}
