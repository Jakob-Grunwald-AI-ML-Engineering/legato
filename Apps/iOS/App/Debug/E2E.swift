#if DEBUG
import AVFAudio
import Foundation
import LegatoCore
import Synchronization
import os

/// Hooks for the simulator end-to-end run (`scripts/e2e/ios-sim.sh`). Debug builds only.
///
/// Launch arguments (read from the argument domain, so `-Key value` works):
/// - `-LegatoFakeEngine "<text>"`: dictate a scripted text with a fake mic instead of Speech + AVAudioEngine.
///   Also reports the microphone and the speech model as ready.
/// - `-LegatoFakeReadiness liveActivitiesDisabled|micPermission|assetsMissing`: report that issue.
/// - `-LegatoForceTapToCopy YES|NO`: sets the `debugForceTapToCopy` setting.
/// - `-LegatoFakeOtherAudio YES|NO`: other audio is (not) playing, whatever the audio session says.
/// - `-LegatoFakeBackground YES|NO`: the app is (not) in the background, whatever UIKit says. The
///   `foreground` / `background` commands flip it, like the app coming forward.
/// - `-LegatoFakeBackgroundRefusal pla|what`: while the fake background is on, the start fails like the
///   device did: `pla` on the session activation ('!pla'), `what` on the mic start (kAUStartIO).
///
/// Darwin notifications (see `installTriggers`): `toggle`, `interrupt`, `copy-last`, `foreground`,
/// `background`, `toggle-after-hop` (the press that repeats a `needsForeground` one after the hop).
/// - `-LegatoKeepAliveSeconds <n>`: sets the keep-alive setting (any number of seconds).
/// - `-LegatoFakeKeyboardApply YES|NO`: whether the fake keyboard types the streamed text into its
///   document and confirms it (default YES). NO leaves the final text unconfirmed.
///
/// URLs: `legato://toggle` calls `AppController.toggle()`; `legato://interrupt` posts the notification
/// the audio session sends on an interruption, so the real observer handles it.
///
/// The fake keyboard (`E2EFakeKeyboard`) stands in for the keyboard extension: it publishes presence,
/// sends requests, and applies the streamed text with the real `ProxyEditPlanner`. Commands
/// `kbd-visible`, `kbd-hidden`, `kbd-request-start|stop|end-keep-alive`, `kbd-hop-start` (the request,
/// then the URL), `kbd-hop-start-url-first` (the URL, then the request).
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

    /// The simulated system facts; nil keeps the real value.
    private struct Fake {
        var inBackground: Bool?
        var otherAudioPlaying: Bool?
    }

    private static let fake = Mutex(Fake(
        inBackground: launchFlag("LegatoFakeBackground"),
        otherAudioPlaying: launchFlag("LegatoFakeOtherAudio")))

    private static func launchFlag(_ key: String) -> Bool? {
        UserDefaults.standard.string(forKey: key).map { ["YES", "TRUE", "1"].contains($0.uppercased()) }
    }

    static var fakeInBackground: Bool? { fake.withLock { $0.inBackground } }
    static var fakeOtherAudioPlaying: Bool? { fake.withLock { $0.otherAudioPlaying } }
    static func setFakeInBackground(_ value: Bool) { fake.withLock { $0.inBackground = value } }

    enum Refusal: String {
        case pla, what

        /// 'pla' = `AVAudioSession.ErrorCode.cannotStartPlaying`, 'what' = kAUStartIO.
        var error: NSError {
            NSError(domain: NSOSStatusErrorDomain, code: self == .pla ? 561_015_905 : 2_003_329_396)
        }
    }

    static let fakeRefusal: Refusal? = UserDefaults.standard.string(forKey: "LegatoFakeBackgroundRefusal").flatMap(Refusal.init)

    /// The error a start should fail with now, when it is `step` that is refused.
    static func refusal(at step: Refusal) -> NSError? {
        guard fakeRefusal == step, fakeInBackground == true else { return nil }
        return step.error
    }

    /// A session wired to the scripted engine, or nil when fake mode is off.
    @MainActor
    static func makeFakeSession(history: any HistoryStore, policy: AudioPolicy, linger: Duration) -> DictationSession? {
        guard let engine = fakeEngine else { return nil }
        log("session.make engine=\(engine.id) lingerSeconds=\(Int(linger.components.seconds))")
        return DictationSession(
            engine: engine,
            source: E2EFakeAudioSource(),
            sessionControl: E2ENoopSessionControl(),
            history: history,
            policy: policy,
            linger: linger)
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
        if UserDefaults.standard.object(forKey: "LegatoKeepAliveSeconds") != nil {
            Settings.keepAliveSeconds = UserDefaults.standard.integer(forKey: "LegatoKeepAliveSeconds")
        }
        if let flag = UserDefaults.standard.string(forKey: "LegatoFakeKeyboardApply") {
            E2EFakeKeyboard.shared.applies = ["YES", "TRUE", "1"].contains(flag.uppercased())
        }
        installTriggers()
        log("launch keepAliveSeconds=\(Settings.keepAliveSeconds) fakeEngine=\(fakeEngine != nil) fakeReadiness=\(String(describing: fakeReadiness)) forceTapToCopy=\(Settings.debugForceTapToCopy) fakeBackground=\(String(describing: fakeInBackground)) fakeOtherAudio=\(String(describing: fakeOtherAudioPlaying))")
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

    /// `toggle`, `interrupt`, `copy-last`, `foreground`, `background`, `toggle-after-hop` or one of the `kbd-` commands.
    func runE2E(_ command: String) async {
        E2E.log("command \(command)")
        if command.hasPrefix("kbd-") {
            await E2EFakeKeyboard.shared.run(command)
            return
        }
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
        case "foreground":
            E2E.setFakeInBackground(false)
        case "background":
            E2E.setFakeInBackground(true)
        case "toggle-after-hop":
            // What the intent does after `continueInForeground`, with the fake background still on.
            _ = await toggle(afterForegroundHop: .backgroundStartRefused)
        default:
            E2E.log("command.unknown \(command)")
        }
    }
}

extension E2E {
    static let commands = [
        "toggle", "interrupt", "copy-last", "foreground", "background", "toggle-after-hop",
        "kbd-visible", "kbd-hidden", "kbd-request-start", "kbd-request-stop", "kbd-request-end-keep-alive",
        "kbd-hop-start", "kbd-hop-start-url-first",
    ]

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
