import Foundation

/// A bounded metadata projection for offline replay. Each row belongs to a stable, locally observed take.
public struct StyleDiagnosticEvent: Codable, Equatable, Sendable {
    public enum Platform: String, Codable, Sendable { case iOS, macOS }
    public enum Action: String, Codable, Sendable {
        case typed, suggestion, hostEdit, request, magic, cleanup, inserted, undo, deleted, finalized, boundary
    }
    /// The production cleanup mode when the producer knows it. Absence is an unknown mode.
    public enum Mode: String, Codable, Sendable { case line, send, off }
    /// Only an explicit host trait can identify a send field. Generic editable text is ambiguous.
    public enum Context: String, Codable, Sendable { case unknown, sendField, proseField }
    public enum Instruction: String, Codable, Sendable {
        case none, addEmoji, avoidEmoji, other

        /// Recognize a few unambiguous standalone commands. Quoted, compound and unfamiliar requests abstain.
        public init(_ words: String?) {
            guard let words else { self = .none; return }
            guard words.utf8.prefix(257).count <= 256 else { self = .other; return }
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self = .none; return }
            let command = words.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            switch command {
            case "add emoji", "add an emoji", "add emojis", "add a smiley", "use emojis",
                 "füge ein emoji hinzu", "füge emojis hinzu", "mit emojis":
                self = .addEmoji
            case "no emoji", "no emojis", "without emojis", "remove emojis", "remove the emojis",
                 "keine emojis", "ohne emojis", "entferne die emojis":
                self = .avoidEmoji
            default: self = .other
            }
        }
    }

    public let v: Int
    public let atMs: Int64
    public let eventID: UUID
    public let takeID: UUID
    public let platform: Platform
    public let action: Action
    public let context: Context
    public let emojiAdded: Int
    public let emojiRemoved: Int
    public let instruction: Instruction
    public let mode: Mode?
    /// On a model result, links back to its request event.
    public let requestID: UUID?

    public init(takeID: UUID, platform: Platform, action: Action, context: Context = .unknown,
                before: String = "", after: String = "", instruction: String? = nil,
                eventID: UUID = UUID(), at: Date = Date(), mode: Mode? = nil, requestID: UUID? = nil) {
        self.init(takeID: takeID, platform: platform, action: action, context: context, before: before,
                  after: after, instructionKind: Instruction(instruction), eventID: eventID, at: at, mode: mode, requestID: requestID)
    }

    public init(takeID: UUID, platform: Platform, action: Action, context: Context = .unknown,
                before: String = "", after: String = "", instructionKind: Instruction,
                eventID: UUID = UUID(), at: Date = Date(), mode: Mode? = nil, requestID: UUID? = nil) {
        v = 1
        atMs = Int64(at.timeIntervalSince1970 * 1000)
        self.eventID = eventID
        self.takeID = takeID
        self.platform = platform
        self.action = action
        self.context = context
        instruction = instructionKind
        self.mode = mode
        self.requestID = requestID
        var counts: [Character: Int] = [:]
        for glyph in before where Self.isEmoji(glyph) { counts[glyph, default: 0] -= 1 }
        for glyph in after where Self.isEmoji(glyph) { counts[glyph, default: 0] += 1 }
        emojiAdded = counts.values.reduce(0) { $0 + max(0, $1) }
        emojiRemoved = counts.values.reduce(0) { $0 + max(0, -$1) }
    }

    public static func containsEmoji(_ text: String) -> Bool { text.contains(where: isEmoji) }

    /// Count a rendered emoji grapheme once (including flags, modifiers, keycaps and ZWJ sequences).
    /// ASCII digits and text-default symbols count only with their emoji presentation or keycap selector.
    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard !scalars.contains("\u{FE0E}") else { return false }
        return scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.contains { $0.properties.isEmoji } && (scalars.contains("\u{FE0F}") || scalars.contains("\u{20E3}")))
    }
}

/// Internal app and keyboard targets opt into this writer. Content is reduced to closed enums, IDs and counts
/// before encoding. The existing process-safe writer handles rotation and shared app-group appends.
/// The serial queue exclusively owns the non-Sendable rotating file and every append.
public final class StyleDiagnosticLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "legato.style-diagnostics", qos: .utility)
    private let file: RotatingLineFile
    private let settings: CorrectionStore
    public let platform: StyleDiagnosticEvent.Platform

    public init(directory: URL, platform: StyleDiagnosticEvent.Platform, settingsRoot: URL) {
        self.platform = platform
        settings = CorrectionStore(root: settingsRoot)
        file = RotatingLineFile(directory: directory, fileName: "style-diag.jsonl", previousFileName: "style-diag.previous.jsonl",
                                rotateBytes: 256 * 1024)
    }

    public func record(takeID: UUID, action: StyleDiagnosticEvent.Action, context: StyleDiagnosticEvent.Context = .unknown,
                       before: String = "", after: String = "", instruction: String? = nil, eventID: UUID = UUID(),
                       mode: StyleDiagnosticEvent.Mode? = nil, requestID: UUID? = nil) {
        record(takeID: takeID, action: action, context: context, before: before, after: after,
               instructionKind: .init(instruction), eventID: eventID, mode: mode, requestID: requestID)
    }

    public func record(takeID: UUID, action: StyleDiagnosticEvent.Action, context: StyleDiagnosticEvent.Context = .unknown,
                       before: String = "", after: String = "", instructionKind: StyleDiagnosticEvent.Instruction,
                       eventID: UUID = UUID(), mode: StyleDiagnosticEvent.Mode? = nil, requestID: UUID? = nil) {
        // A diagnostic cannot measure an oversized edit reliably from a truncated sample.
        guard before.utf8.prefix(65_537).count <= 65_536, after.utf8.prefix(65_537).count <= 65_536 else { return }
        let at = Date()
        queue.async { [self] in
            guard eligible(action: action, at: at) else { return }
            let event = StyleDiagnosticEvent(takeID: takeID, platform: platform, action: action, context: context,
                                             before: before, after: after, instructionKind: instructionKind, eventID: eventID, at: at,
                                             mode: mode, requestID: requestID)
            append(event)
        }
    }

    public func record(_ event: StyleDiagnosticEvent) {
        guard event.platform == platform, event.v == 1 else { return }
        queue.async { [self] in
            guard eligible(action: event.action, at: Date(timeIntervalSince1970: Double(event.atMs) / 1000)) else { return }
            append(event)
        }
    }

    private func eligible(action: StyleDiagnosticEvent.Action, at: Date) -> Bool {
        // A deletion also retracts observations captured before the user turned personalization off.
        if action == .deleted { return true }
        guard let since = try? settings.personalizationEnabledSince() else { return false }
        return since <= at
    }

    private func append(_ event: StyleDiagnosticEvent) {
        guard var bytes = try? JSONEncoder().encode(event) else { return }
        bytes.append(0x0A)
        file.append(bytes)
    }
}
