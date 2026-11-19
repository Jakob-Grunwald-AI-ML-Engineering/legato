import Foundation

public enum RequestCommand: String, Codable, Sendable, Equatable {
    case start, stop, endKeepAlive
    /// Send everything dictated so far to the field now; listening continues.
    case send
    /// Send everything dictated so far that is not typed yet as raw words, with no cleanup (a swipe right on the preview).
    case sendRaw
    /// Throw away what is still in the preview and not yet sent for cleanup: the open unit and the speaking head (a swipe left).
    /// The app keeps it for a short undo window (`undoDiscard`), then drops it.
    case discard
    /// Take back the last discard while its window is open: the words are cleaned and typed as if sent.
    case undoDiscard
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

/// The keyboard surface on screen: typing, which dictates into the field. The one surface there is (the iOS composer
/// screen is retired); the instruction mode is the magic key, not a surface. Kept as the wire value of `KeyboardPresence`.
public enum KeyboardSurface: String, Codable, Sendable, Equatable { case typing }

/// keyboard -> app (`link.presence`): the keyboard is on screen, refreshed while it is.
public struct KeyboardPresence: Codable, Sendable, Equatable {
    public var visible: Bool
    public var at: Date
    public var documentID: String?
    /// nil decodes presences written before surfaces were reported.
    public var surface: KeyboardSurface?
    /// The end of `documentContextBeforeInput` (at most `contextLimit` characters), context for cleaning the
    /// dictated lines. nil for a secure field and before this was reported.
    public var contextBefore: String?
    public static let contextLimit = 400
    /// The magic key (instruction mode); nil decodes presences written before it existed (off).
    public var magic: MagicToggle?
    /// When `magic` last changed (the keyboard's clock).
    public var magicAt: Date?

    public init(visible: Bool, at: Date, documentID: String? = nil, surface: KeyboardSurface? = nil, contextBefore: String? = nil,
                magic: MagicToggle? = nil, magicAt: Date? = nil) {
        self.visible = visible
        self.at = at
        self.documentID = documentID
        self.surface = surface
        self.contextBefore = contextBefore.map { String($0.suffix(Self.contextLimit)) }
        self.magic = magic
        self.magicAt = magicAt
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
