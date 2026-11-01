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
    private var lineBytes: [UInt8] = []
    private var previousWasCR = false
    public init() {}

    /// Preserve empty SSE lines; AsyncBytes.lines omits the frame delimiters.
    /// Decode only complete lines so split UTF-8 code points remain intact.
    public mutating func consume(byte: UInt8) -> SSEEvent? {
        if previousWasCR && byte == 10 {
            previousWasCR = false
            return nil
        }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 {
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            return consume(line: line)
        }
        lineBytes.append(byte)
        return nil
    }

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
