import Foundation

public struct SonioxConfig: Sendable {
    public static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    public let general: String
    public let terms: [String]
    public var estimatedContextTokens: Int { general.utf8.count + terms.reduce(0) { $0 + $1.utf8.count + 4 } }
    public init(mode: String = "Note", personalPrompt: String = "", terms: [String] = []) {
        // One UTF-8 byte per estimated token is conservative for multilingual text. Leave margin for schema.
        var remaining = 7500
        var selected: [String] = []
        for term in terms.prefix(100) where !term.isEmpty {
            let bytes = term.utf8.count + 4
            guard bytes <= remaining else { continue }
            selected.append(term); remaining -= bytes
        }
        self.terms = selected
        var summary = "Mode: \(mode)\n\(personalPrompt)"
        while summary.utf8.count > remaining { summary.removeLast() }
        self.general = summary
    }
    public func request(apiKey: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
    public func message() throws -> Data {
        let context: [String: Any] = ["general": [["key": "composer", "value": general]], "terms": terms]
        return try JSONSerialization.data(withJSONObject: [
            "model": "stt-rt-v5", "audio_format": "pcm_s16le", "sample_rate": 16000, "num_channels": 1,
            "language_hints": ["de", "en"], "enable_language_identification": true,
            "enable_endpoint_detection": true, "context": context
        ], options: [.sortedKeys])
    }
}
