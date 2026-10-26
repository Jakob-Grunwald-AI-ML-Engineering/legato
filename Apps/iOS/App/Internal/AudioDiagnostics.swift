#if LEGATO_INTERNAL
import ActivityKit
import AVFAudio
import Foundation
import LegatoAudio
import LegatoCore
import Synchronization
import UIKit

/// Device experiment for the background second-start failure: appends one JSON object per line to
/// `Library/Caches/audio-diag.jsonl` in the app's data container. Debug and TestFlight builds only
/// (`LEGATO_INTERNAL`); App Store builds do not contain it.
///
/// Pull the file from a connected device:
///
///     xcrun devicectl device copy from --device <device> --domain-type appDataContainer \
///       --domain-identifier de.gruenwald.legato --source Library/Caches/audio-diag.jsonl \
///       --destination ./audio-diag.jsonl
///
/// Every line carries the same snapshot (time, pid, app state, session category/options, route, other
/// audio, Live Activity count, settings) plus the event's own fields. Events: `launch`, `toggle.begin`,
/// `toggle.end`, `session.step` (each AVAudioSession call: setCategory, setPreferredInput,
/// setActiveTrue, setActiveFalse, with its own error), `session.activate` / `session.deactivate` /
/// `session.deactivate.skipped` / `session.release` (the wrapper's view), and `mic.attempt` (one engine
/// start attempt: index, input sample rate, channels, error), `mic.firstBuffer` (ms to the first buffer, RMS of the first ~0.5 s) and `start.fallback` (a refused background start retried under the default policy: `from`, `to`, the `refusal` as a FourCC or name, and the `error`) and `start.route` (how a start was routed: `route`
/// is `background`, `foreground` or `foregroundHop`, with the `reason` of a hop, `backgroundStartRefused`, the
/// `outcome` and `otherAudio`, whether other audio played when the start began). `setActive(true)` and the engine start are separate
/// events, so a failure in one is never attributed to the other. The file is cleared past 1 MB.
enum AudioDiagnostics {
    static let fileName = "audio-diag.jsonl"
    private static let maxBytes = 1_000_000

    static var fileURL: URL { URL.cachesDirectory.appending(path: fileName) }

    private static let queue = DispatchQueue(label: "de.gruenwald.legato.audio-diag")
    /// `UIApplication.applicationState` is main-actor only and events arrive from any thread, so the
    /// state is cached from the lifecycle notifications.
    private static let appState = Mutex("unknown")

    /// Call once from the main actor at launch.
    @MainActor
    static func install() {
        appState.withLock { $0 = describe(UIApplication.shared.applicationState) }
        let center = NotificationCenter.default
        let observed: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "inactive"),
        ]
        for (name, state) in observed {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in appState.withLock { $0 = state } }
        }
        log("launch")
    }

    /// Appends one event. Safe from any thread; the file write happens on a serial queue.
    static func log(_ event: String, _ fields: [String: Any] = [:]) {
        var line = snapshot()
        line["event"] = event
        for (key, value) in fields { line[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        queue.async { append(data + [0x0A]) }
    }

    // MARK: Hooks

    /// The observer for `AudioSessionController` and the hook for `MicSource`.
    static func sessionStep(_ step: AudioSessionController.Step, _ error: (any Error)?) {
        log("session.step", ["step": step.rawValue, "ok": error == nil, "error": describe(error)])
    }

    static func startRoute(_ route: String, reason: String?, outcome: String, otherAudio: Bool) {
        log("start.route", ["route": route, "reason": reason ?? "none", "outcome": outcome, "otherAudio": otherAudio])
    }

    /// A refused background start retried once under the default policy.
    static func startFallback(from: String, to: String, error: any Error, label: String) {
        log("start.fallback", ["from": from, "to": to, "refusal": label, "error": describe(error)])
    }

    static func micAttempt(_ attempt: MicSource.Attempt) {
        log("mic.attempt", [
            "attempt": attempt.index,
            "inputSampleRate": attempt.inputSampleRate,
            "inputChannels": attempt.inputChannelCount,
            "ok": attempt.error == nil,
            "error": describe(attempt.error),
        ])
    }

    /// Logged once ~0.5 s after the engine starts. Absent for a run = no buffer ever arrived; an `rms`
    /// near 0 = buffers arrived but silent (the "no signal" case).
    static func micFirstBuffer(_ b: MicSource.FirstBuffer) {
        log("mic.firstBuffer", [
            "msSinceStart": b.msSinceStart,
            "rms": b.rms,
            "frames": b.frames,
            "inputSampleRate": b.sampleRate,
            "silent": b.rms < 1e-5,
        ])
    }

    // MARK: Snapshot

    private static func snapshot() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        return [
            "t": ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds]),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "appState": appState.withLock { $0 },
            "otherAudioPlaying": session.isOtherAudioPlaying,
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "options": options(session.categoryOptions),
            "inputs": route.inputs.map { "\($0.portType.rawValue):\($0.portName)" },
            "outputs": route.outputs.map { "\($0.portType.rawValue):\($0.portName)" },
            "availableInputs": session.availableInputs?.count ?? 0,
            "sessionSampleRate": session.sampleRate,
            "liveActivities": Activity<DictationAttributes>.activities.count,
            "settings": [
                "keepSessionActiveBetweenRuns": Settings.keepSessionActiveBetweenRuns,
                "policy": Settings.audioPolicy.rawValue,
            ] as [String: Any],
        ]
    }

    private static func options(_ o: AVAudioSession.CategoryOptions) -> [String] {
        var names: [String] = []
        if o.contains(.mixWithOthers) { names.append("mixWithOthers") }
        if o.contains(.duckOthers) { names.append("duckOthers") }
        if o.contains(.allowBluetoothA2DP) { names.append("allowBluetoothA2DP") }
        if o.contains(.defaultToSpeaker) { names.append("defaultToSpeaker") }
        if o.contains(.allowBluetoothHFP) { names.append("allowBluetoothHFP") }
        if o.contains(.interruptSpokenAudioAndMixWithOthers) { names.append("interruptSpokenAudioAndMixWithOthers") }
        return names
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    /// nil (JSON null) when there is no error; else domain, code, the code as a FourCC when it is one
    /// (`560030580` is `!act`), and the description.
    static func describe(_ error: (any Error)?) -> Any {
        guard let error else { return NSNull() }
        let ns = error as NSError
        var out: [String: Any] = ["domain": ns.domain, "code": ns.code, "description": ns.localizedDescription]
        if let fourCC = fourCC(ns.code) { out["fourcc"] = fourCC }
        return out
    }

    static func fourCC(_ code: Int) -> String? {
        guard code > 0, code <= Int(UInt32.max) else { return nil }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: File

    private static func append(_ data: Data) {
        let url = fileURL
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// The app's audio-session control: `AudioSessionController` inside LegatoCore's
/// `KeepActiveSessionControl`, plus the internal-build diagnostics.
///
/// - Logs every activate/deactivate to `AudioDiagnostics` (`session.activate` carries the requested
///   options and what was done: `activated`, `reused`, `reconfigured`, `keptCurrent`, `reactivated`).
/// - `Settings.keepSessionActiveBetweenRuns`: a normal stop does not deactivate the session, so the
///   next run finds it live. A background start must not re-run `setCategory` on it (iOS refuses with
///   '!int'), so a held session is reused as is. While it is held, other apps' audio stays ducked or
///   paused under the policy that was active. A system event (interruption, media reset, lost input)
///   still deactivates: `release()`.
///
/// One instance lives for the whole process; sessions are built per dictation.
extension KeepActiveSessionControl {
    static func app() -> KeepActiveSessionControl {
        KeepActiveSessionControl(
            inner: AudioSessionController(observer: AudioDiagnostics.sessionStep),
            keepActive: { Settings.keepSessionActiveBetweenRuns },
            hasLiveInput: { !AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty },
            isRefusal: { SystemStartEnvironment.isRefusal($0) },
            observer: AudioDiagnostics.sessionEvent)
    }
}

extension AudioDiagnostics {
    static func sessionEvent(_ event: KeepActiveSessionControl.Event) {
        switch event {
        case .activate(let requested, let wasHeld, let result):
            var fields: [String: Any] = [
                "ok": true, "wasHeld": wasHeld, "requested": optionNames(requested.options),
            ]
            switch result {
            case .activated: fields["result"] = "activated"
            case .reused: fields["result"] = "reused"
            case .reconfigured: fields["result"] = "reconfigured"
            case .reactivated: fields["result"] = "reactivated"
            case .keptCurrent(let error):
                fields["result"] = "keptCurrent"
                fields["error"] = describe(error)
            }
            log("session.activate", fields)
        case .activateFailed(let requested, let wasHeld, let error):
            log("session.activate", [
                "ok": false, "wasHeld": wasHeld, "requested": optionNames(requested.options), "error": describe(error),
            ])
        case .deactivateSkipped: log("session.deactivate.skipped")
        case .deactivated: log("session.deactivate")
        case .released(let reason, let wasHeld): log("session.release", ["reason": reason, "wasHeld": wasHeld])
        }
    }

    /// The options a `SessionConfig` asks for, by name (the snapshot's `options` is the session's state
    /// *after* the call, so a refused `setCategory` shows what the session kept, not what was asked).
    private static func optionNames(_ o: SessionConfig.Options) -> [String] {
        var names: [String] = []
        if o.contains(.mixWithOthers) { names.append("mixWithOthers") }
        if o.contains(.duckOthers) { names.append("duckOthers") }
        if o.contains(.allowBluetoothA2DP) { names.append("allowBluetoothA2DP") }
        if o.contains(.defaultToSpeaker) { names.append("defaultToSpeaker") }
        if o.contains(.interruptSpokenAudio) { names.append("interruptSpokenAudioAndMixWithOthers") }
        return names
    }
}
#endif
