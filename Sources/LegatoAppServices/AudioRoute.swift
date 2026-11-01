import Foundation

/// Where microphone audio goes while a keyboard session holds the warm input. `idle` discards it.
public enum AudioRoute: String, Sendable, Codable, CaseIterable { case idle, dictation, agent }

/// The mic key's gate. The surface on screen decides which route a tap opens; a tap never opens
/// another surface's route, and leaving a surface closes whatever was open.
public struct AudioGate: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Start sending audio to `route`.
        case open(AudioRoute)
        /// Stop sending audio and finalize what `route` heard.
        case finalize(AudioRoute)
        /// Stop sending audio and drop `route`'s unfinished words (surface change, keyboard gone).
        case abandon(AudioRoute)
    }
    /// The route a tap opens on the current surface; never `idle`.
    public private(set) var surface: AudioRoute
    public private(set) var route = AudioRoute.idle
    public init(surface: AudioRoute = .agent) { self.surface = surface == .idle ? .agent : surface }

    /// A tap opens the current surface's route, or finalizes the open one.
    public mutating func tap() -> Action {
        if route != .idle { return close() }
        route = surface
        return .open(surface)
    }
    /// The mic key's stop: finalize the open route, if any.
    public mutating func close() -> Action {
        let closed = route
        route = .idle
        return .finalize(closed)
    }
    /// A different surface: abandon the open route (if any) and re-route later taps.
    public mutating func show(_ value: AudioRoute) -> Action? {
        let next = value == .idle ? AudioRoute.agent : value
        guard next != surface else { return nil }
        surface = next
        return abandon()
    }
    /// The keyboard went away: drop the open route's unfinished words.
    public mutating func abandon() -> Action? {
        guard route != .idle else { return nil }
        let closed = route
        route = .idle
        return .abandon(closed)
    }
}
