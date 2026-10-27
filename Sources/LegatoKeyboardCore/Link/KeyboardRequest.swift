import Foundation

public enum RequestCommand: String, Codable, Sendable, Equatable {
    case start, stop, endKeepAlive
    /// Ready the microphone (a lease, no run) with the app in front: what the keyboard asks when it has to
    /// open the app. The app can't act on it from the background, so it is only ever acted on through the URL.
    case arm
}

/// keyboard -> app (`link.request`): sent twice, as this value plus a Darwin note, and (when the app
/// has to be opened) as the same id inside `KeyboardURL`. `RequestLedger` dedupes the copies.
public struct KeyboardRequest: Codable, Sendable, Equatable {
    public var id: String
    public var command: RequestCommand
    public var at: Date

    public init(id: String, command: RequestCommand, at: Date) {
        self.id = id
        self.command = command
        self.at = at
    }
}

public enum AckResult: String, Codable, Sendable, Equatable {
    /// The app is acting on the request.
    case accepted
    /// The app can't act from where it is: the keyboard must open it.
    case hop
}

/// app -> keyboard (`link.ack`).
public struct KeyboardAck: Codable, Sendable, Equatable {
    public var id: String
    public var result: AckResult

    public init(id: String, result: AckResult) {
        self.id = id
        self.result = result
    }
}

/// keyboard -> app (`link.presence`): the keyboard is on screen, refreshed while it is.
public struct KeyboardPresence: Codable, Sendable, Equatable {
    public var visible: Bool
    public var at: Date

    public init(visible: Bool, at: Date) {
        self.visible = visible
        self.at = at
    }

    public func isFresh(now: Date) -> Bool {
        visible && now.timeIntervalSince(at) < LinkChannel.presenceFreshness
    }
}

/// `legato://keyboard?cmd=<command>&req=<id>`: how the keyboard asks the app to be opened.
public enum KeyboardURL {
    public static func make(command: RequestCommand, requestID: String, identity: RuntimeIdentity = .current) -> URL {
        var parts = URLComponents()
        parts.scheme = identity.urlScheme
        parts.host = "keyboard"
        parts.queryItems = [URLQueryItem(name: "cmd", value: command.rawValue), URLQueryItem(name: "req", value: requestID)]
        return parts.url!
    }

    public static func parse(_ url: URL, identity: RuntimeIdentity = .current) -> (command: RequestCommand, requestID: String)? {
        guard url.scheme == identity.urlScheme, url.host == "keyboard",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "cmd" })?.value, let command = RequestCommand(rawValue: raw),
              let id = items.first(where: { $0.name == "req" })?.value, !id.isEmpty
        else { return nil }
        return (command, id)
    }
}

/// keyboard -> app (`link.refine`): rewrite this dictation more strongly (the app's message style). The app
/// acks it with a `KeyboardAck` of the same id at once, answers with a `RefineReply`, and removes the
/// request (it carries dictated text) once read.
public struct RefineRequest: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var at: Date

    public init(id: String, text: String, at: Date) {
        self.id = id
        self.text = text
        self.at = at
    }
}

/// app -> keyboard (`link.refined`): the refined text, or nil when there is no better version (no model, or
/// the result was rejected).
public struct RefineReply: Codable, Sendable, Equatable {
    public var id: String
    public var text: String?

    public init(id: String, text: String?) {
        self.id = id
        self.text = text
    }
}
