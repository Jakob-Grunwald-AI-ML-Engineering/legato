import Foundation

/// SessionLog is written exclusively by its owning Room actor after construction.
public final class SessionLog: Sendable {
    public let directory: URL
    public let roomURL: URL
    public let finalURL: URL
    public let audioURL: URL
    private let secrets: [String]
    public init(rootDirectory: URL, sessionID: String = UUID().uuidString, secrets: [String] = []) throws {
        guard !sessionID.isEmpty, !sessionID.contains("/"), sessionID != ".", sessionID != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        directory = rootDirectory.appendingPathComponent(sessionID, isDirectory: true)
        roomURL = directory.appendingPathComponent("room.jsonl")
        finalURL = directory.appendingPathComponent("final.md")
        audioURL = directory.appendingPathComponent("audio.m4a")
        self.secrets = secrets.filter { !$0.isEmpty }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: roomURL.path) else { throw CocoaError(.fileWriteFileExists) }
        try Data().write(to: roomURL, options: .withoutOverwriting)
    }
    func append(_ envelope: Envelope) throws {
        // Redact structurally before encoding so newline/quote-containing secrets cannot bypass filtering.
        let value = try JSONValue.encoding(envelope)
        var data = try JSONEncoder().encode(redacted(value))
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: roomURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    func finish(_ text: String) throws {
        try redactString(text).write(to: finalURL, atomically: true, encoding: .utf8)
    }
    private func redacted(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(redactString(text))
        case .array(let values): return .array(values.map(redacted))
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (key, value) in fields {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                let sensitive = ["authorization", "apikey", "xapikey", "anthropickey", "sonioxkey", "accesskey", "accesstoken", "bearer", "secret", "password"].contains(normalized)
                result[redactString(key)] = sensitive ? .string("[REDACTED]") : redacted(value)
            }
            return .object(result)
        default: return value
        }
    }
    private func redactString(_ text: String) -> String {
        var result = text
        for secret in secrets { result = result.replacingOccurrences(of: secret, with: "[REDACTED]") }
        result = result.replacingOccurrences(of: #"(?i)Bearer\s+[^\s\"]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
        result = result.replacingOccurrences(of: #"sk-(?:ant-)?[A-Za-z0-9_-]{12,}"#, with: "[REDACTED]", options: .regularExpression)
        return result
    }
}
