import Foundation

public enum RemoteAction: Sendable, Equatable { case start, stop }

/// What tapping the mic key does, from the app's last published state.
public enum MicKeyMode: Sendable, Equatable {
    /// The keyboard can't read the App Group without Full Access: show an explainer.
    case needsFullAccess
    /// Open the app (`legato://keyboard?cmd=start&req=…`), and post the same request id as a Darwin note.
    case openApp
    /// Ask the running app over the link. With no ack within `LinkChannel.ackTimeout`, or an ack of
    /// `hop`, fall back to `.openApp`.
    case remote(RemoteAction)

    public static func resolve(host: HostState?, now: Date, fullAccess: Bool) -> MicKeyMode {
        guard fullAccess else { return .needsFullAccess }
        guard let host, now.timeIntervalSince(host.beatAt) < LinkChannel.beatFreshness else { return .openApp }
        switch host.phase {
        case .starting, .listening:
            return .remote(.stop)
        case .idle, .finishing:
            let leaseHeld = host.leaseUntil.map { $0 > now } ?? true
            return host.acceptsRemoteStart && leaseHeld ? .remote(.start) : .openApp
        }
    }
}
