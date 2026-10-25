#if DEBUG
import AVFAudio
import Foundation
import LegatoCore
import os

/// Hooks for the simulator end-to-end run (`scripts/e2e/ios-sim.sh`). Debug builds only.
///
/// Launch arguments (read from the argument domain, so `-Key value` works):
/// - `-LegatoFakeEngine "<text>"`: dictate a scripted text with a fake mic instead of Speech + AVAudioEngine.
///   Also reports the microphone and the speech model as ready.
/// - `-LegatoFakeReadiness liveActivitiesDisabled|micPermission|assetsMissing`: report that issue.
/// - `-LegatoForceTapToCopy YES|NO`: sets the `debugForceTapToCopy` setting.
/// - `-LegatoFakeOtherAudio <ms>`: other audio "plays" for this long from each session's creation, so the
///   start has to wait for it (`OtherAudioGate`).
///
/// URLs: `legato://toggle` calls `AppController.toggle()`; `legato://interrupt` posts the notification
/// the audio session sends on an interruption, so the real observer handles it.
///
/// Every line is logged at notice level as `e2e <event> key=value ...` (subsystem de.gruenwald.legato,
/// category e2e).
enum E2E {
    private static let logger = Logger(subsystem: "de.gruenwald.legato", category: "e2e")

    static func log(_ message: String) {
        logger.notice("e2e \(message, privacy: .public)")
    }

    /// Quoted for log lines; the script parses `tail="..."`.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    static let fakeEngine: E2EScriptedEngine? = {
        guard let text = UserDefaults.standard.string(forKey: "LegatoFakeEngine"), !text.isEmpty else { return nil }
        let delay = UserDefaults.standard.integer(forKey: "LegatoFakeWordDelayMs")
        return E2EScriptedEngine(text: text, wordDelay: .milliseconds(delay > 0 ? delay : 150))
    }()

    static let fakeReadiness: ReadinessIssue? = {
        switch UserDefaults.standard.string(forKey: "LegatoFakeReadiness") {
        case "liveActivitiesDisabled": .liveActivitiesDisabled
        case "micPermission": .micPermission
        case "assetsMissing": .assetsMissing
        default: nil
        }
    }()

    static let fakeOtherAudio: Duration? = {
        let ms = UserDefaults.standard.integer(forKey: "LegatoFakeOtherAudio")
        return ms > 0 ? .milliseconds(ms) : nil
    }()

    /// A session wired to the scripted engine, or nil when fake mode is off.
    @MainActor
    static func makeFakeSession(history: any HistoryStore, policy: AudioPolicy) -> DictationSession? {
        guard let engine = fakeEngine else { return nil }
        log("session.make engine=\(engine.id)")
        let playingUntil = fakeOtherAudio.map { ContinuousClock.now + $0 }
        let gated = OtherAudioGate(
            engine: engine,
            isOtherAudioPlaying: { playingUntil.map { ContinuousClock.now < $0 } ?? false },
            report: OtherAudioGate.report)
        return DictationSession(
            engine: gated,
            source: E2EFakeAudioSource(),
            sessionControl: E2ENoopSessionControl(),
            history: history,
            policy: policy,
            linger: .zero)
    }

    /// Applies the status overrides to what the system reports.
    static func adjust(_ status: inout ReadinessStatus) {
        if fakeEngine != nil {
            status.micGranted = true
            status.micDenied = false
            status.assetsInstalled = true
        }
        switch fakeReadiness {
        case .micPermission: status.micGranted = false
        case .liveActivitiesDisabled: status.activitiesEnabled = false
        case .assetsMissing: status.assetsInstalled = false
        case nil: break
        }
    }

    @MainActor
    static func applyLaunchSettings() {
        if let flag = UserDefaults.standard.string(forKey: "LegatoForceTapToCopy") {
            Settings.debugForceTapToCopy = ["YES", "TRUE", "1"].contains(flag.uppercased())
        }
        installTriggers()
        log("launch fakeEngine=\(fakeEngine != nil) fakeReadiness=\(String(describing: fakeReadiness)) forceTapToCopy=\(Settings.debugForceTapToCopy)")
    }
}

extension AppController {
    /// Handles the debug-only URLs. Returns whether `url` was one of them.
    func handleE2E(_ url: URL) async -> Bool {
        guard url.scheme == "legato", let command = url.host, command == "toggle" || command == "interrupt" else {
            return false
        }
        await runE2E(command)
        return true
    }

    /// `toggle`, `interrupt` or `copy-last`.
    func runE2E(_ command: String) async {
        E2E.log("command \(command)")
        switch command {
        case "toggle":
            _ = await toggle()
        case "interrupt":
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        case "copy-last":
            await handle(DictationAttributes.copyLastURL)
        default:
            E2E.log("command.unknown \(command)")
        }
    }
}

extension E2E {
    static let commands = ["toggle", "interrupt", "copy-last"]

    /// Darwin notifications `de.gruenwald.legato.e2e.<command>`, posted from the host with
    /// `xcrun simctl spawn <udid> notifyutil -p <name>`. `simctl openurl` with a custom scheme stops at
    /// a system "Open in Legato?" dialog that nothing headless can tap, so the script uses these.
    @MainActor
    static func installTriggers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in commands {
            CFNotificationCenterAddObserver(
                center, nil,
                { _, _, name, _, _ in
                    guard let raw = name?.rawValue as String?, let command = raw.split(separator: ".").last.map(String.init)
                    else { return }
                    Task { @MainActor in await AppController.shared.runE2E(command) }
                },
                "de.gruenwald.legato.e2e.\(command)" as CFString, nil, .deliverImmediately)
        }
    }
}
#endif
