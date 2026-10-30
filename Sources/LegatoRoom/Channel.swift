public enum Channel: String, Codable, CaseIterable, Sendable {
    case asrTail = "asr.tail", asrSegment = "asr.segment", userIntent = "user.intent"
    case hint, docOps = "doc.ops", docSnapshot = "doc.snapshot"
    case agentStatus = "agent.status", alternatives, session
    public var isDocument: Bool { self == .docOps || self == .docSnapshot }
}
