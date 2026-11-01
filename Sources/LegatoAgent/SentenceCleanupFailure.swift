import Foundation
import LegatoClaude
import LegatoRoom

/// Only allowlisted categories reach diagnostics/UI; provider bodies and localized errors may contain private data.
struct SentenceCleanupFailure: Sendable, Equatable {
    let code: String
    let stage: String
    let summary: String
    var httpStatus: Int? = nil
    var stopReason: String? = nil

    static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .init(code: "cancelled", stage: "transport", summary: "request cancelled") }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return .init(code: "timeout", stage: "transport", summary: "request timed out")
            case .cancelled: return .init(code: "cancelled", stage: "transport", summary: "request cancelled")
            default: return .init(code: "connection", stage: "transport", summary: "connection interrupted")
            }
        }
        if let error = error as? MessagesStreamError {
            switch error {
            case .missingKey: return .init(code: "missing_key", stage: "provider", summary: "Claude key is missing")
            case .http(let status, _):
                let category: (String, String)
                switch status {
                case 401, 403: category = ("authentication", "Claude key was rejected")
                case 429: category = ("rate_limit", "provider rate limit")
                case 500...599: category = ("provider_unavailable", "provider temporarily unavailable")
                default: category = ("http_error", "provider rejected the request")
                }
                return .init(code: category.0, stage: "provider", summary: category.1, httpStatus: status)
            case .provider(let body):
                let value = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
                let type = value?["error"]?["type"]
                if type == .string("overloaded_error") { return .init(code: "provider_unavailable", stage: "provider", summary: "provider temporarily unavailable") }
                if type == .string("rate_limit_error") { return .init(code: "rate_limit", stage: "provider", summary: "provider rate limit") }
                return .init(code: "provider_error", stage: "provider", summary: "provider stream failed")
            case .incomplete: return .init(code: "incomplete_stream", stage: "transport", summary: "response stream ended early")
            }
        }
        if let error = error as? SentenceCleanupError {
            switch error {
            case .invalidInput: return .init(code: "invalid_input", stage: "validation", summary: "sentence exceeded input limits")
            case .unexpectedResponse: return .init(code: "invalid_response", stage: "validation", summary: "unexpected response format")
            case .invalidIdentity: return .init(code: "invalid_identity", stage: "validation", summary: "response identity did not match")
            case .invalidText: return .init(code: "invalid_text", stage: "validation", summary: "response text failed validation")
            case .incomplete: return .init(code: "incomplete_response", stage: "validation", summary: "response was incomplete")
            case .providerError: return .init(code: "provider_error", stage: "provider", summary: "provider stream failed")
            case .outputLimit: return .init(code: "output_limit", stage: "provider", summary: "response reached its token limit", stopReason: "max_tokens")
            case .refused: return .init(code: "refusal", stage: "provider", summary: "provider declined this sentence", stopReason: "refusal")
            }
        }
        return .init(code: "unexpected_failure", stage: "cleanup", summary: "unexpected processing error")
    }
    var fields: [String: JSONValue] {
        var result: [String: JSONValue] = ["failureCode": .string(code), "failureStage": .string(stage)]
        if let httpStatus { result["httpStatus"] = .number(Double(httpStatus)) }
        if let stopReason { result["stopReason"] = .string(stopReason) }
        return result
    }
}
