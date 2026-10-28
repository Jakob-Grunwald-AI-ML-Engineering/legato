import Foundation

public enum RemoteAction: Sendable, Equatable { case start, stop }

/// What tapping the mic key does, from the app's last published state.
public enum MicKeyMode: Sendable, Equatable {
    /// The keyboard can't read the App Group without Full Access: show an explainer.
    case needsFullAccess
    /// Open the app (`legato://keyboard?cmd=arm&req=…`) to arm the microphone, and post the same request id
    /// as a Darwin note. The dictation starts with the next tap, back in the host app.
    case openApp
    /// Ask the running app over the link. With no ack within `LinkChannel.ackTimeout`, or an ack of
    /// `hop`, fall back to `.openApp`.
    case remote(RemoteAction)

    /// The request a tap on the key sends (and, for `.openApp`, puts in the URL). Opening the app only
    /// *arms* the mic: the app is in front of the host app's field then, and a run started there could not
    /// type into it. The dictation starts with the next tap, back in the host app, as a remote start.
    public var request: RequestCommand? {
        switch self {
        case .needsFullAccess: nil
        case .openApp: .arm
        case .remote(let action): action == .start ? .start : .stop
        }
    }

    public static func resolve(host: HostState?, now: Date, fullAccess: Bool) -> MicKeyMode {
        guard fullAccess else { return .needsFullAccess }
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return .openApp }
        if host.preparingRequestID != nil { return .remote(.stop) }
        switch host.phase {
        case .starting, .listening:
            return .remote(.stop)
        case .idle, .finishing:
            let leaseHeld = host.leaseUntil.map { $0 > now } ?? true
            return host.acceptsRemoteStart && leaseHeld ? .remote(.start) : .openApp
        }
    }
}
