import Foundation

public struct SSEEvent: Sendable, Equatable {
    public let event: String
    public let data: String
    public init(event: String, data: String) { self.event = event; self.data = data }
}
/// Incremental SSE framing; comments and unknown fields are ignored, data lines join with newlines.
public struct SSEParser: Sendable {
    private var event = "message"
    private var data: [String] = []
    public init() {}
    public mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { event = "message"; data = [] }
            return data.isEmpty ? nil : SSEEvent(event: event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix("event:") { event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5)); if value.first == " " { value.removeFirst() }; data.append(value)
        }
        return nil
    }
}
