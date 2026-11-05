import AVFAudio
import Foundation
import os

/// Which input the session should prefer. Built-in while the mic is only held (the headset stays in
/// music mode, so its stem controls keep driving the media app); a Bluetooth headset mic for a take.
public enum PreferredInputKind: String, Sendable { case builtIn, bluetooth }

/// One available input port, reduced to what the choice needs (no names, no UIDs in logs).
public struct InputPortInfo: Sendable, Equatable {
    public enum Kind: String, Sendable { case builtIn, bluetooth, other }
    public let id: String
    public let kind: Kind
    public init(id: String, kind: Kind) { self.id = id; self.kind = kind }
}

public enum PreferredInputRoute {
    /// The port to prefer, or nil to leave the system's choice.
    public static func choose(_ kind: PreferredInputKind, among ports: [InputPortInfo]) -> InputPortInfo? {
        switch kind {
        case .builtIn: ports.first { $0.kind == .builtIn }
        case .bluetooth: ports.first { $0.kind == .bluetooth }
        }
    }

    #if os(iOS)
    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "audio-route")

    /// `setPreferredInput` changes no category or options, so it is the one route change a background
    /// session accepts. It never throws: a refusal is logged and whatever input is live carries on.
    /// Returns whether the preference was applied.
    @discardableResult
    public static func apply(_ kind: PreferredInputKind) -> Bool {
        let session = AVAudioSession.sharedInstance()
        // The combined session owns both ports. An idle/take preference must not collapse
        // it to one microphone or trigger a route transition at the start of speech.
        if #available(iOS 26.2, *), session.mode == .dualRoute { return false }
        let available = session.availableInputs ?? []
        let ports = available.map { InputPortInfo(id: $0.uid, kind: Self.kind(of: $0.portType)) }
        guard let chosen = choose(kind, among: ports), let port = available.first(where: { $0.uid == chosen.id }) else {
            log.info("prefer \(kind.rawValue, privacy: .public) skipped: no matching port, available=\(ports.count) live=\(liveTypes(session), privacy: .public)")
            return false
        }
        do {
            try session.setPreferredInput(port)
            log.info("prefer \(kind.rawValue, privacy: .public) port=\(port.portType.rawValue, privacy: .public) ok live=\(liveTypes(session), privacy: .public)")
            return true
        } catch {
            let status = (error as NSError).code
            log.error("prefer \(kind.rawValue, privacy: .public) port=\(port.portType.rawValue, privacy: .public) refused osstatus=\(status) live=\(liveTypes(session), privacy: .public)")
            return false
        }
    }

    private static func kind(of type: AVAudioSession.Port) -> InputPortInfo.Kind {
        switch type {
        case .builtInMic: .builtIn
        case .bluetoothHFP, .bluetoothLE: .bluetooth
        default: .other
        }
    }
    private static func liveTypes(_ session: AVAudioSession) -> String {
        session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
    }
    #endif
}
