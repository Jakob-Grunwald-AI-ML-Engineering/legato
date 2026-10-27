#if DEBUG
import AVFAudio
import Foundation
import LegatoAudio
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
/// - `-LegatoFakeBackgroundRefusal pla|int|what|input`: while the fake background is on, the start fails
///   like the device did: `pla` ('!pla') or `int` ('!int') on the session activation, `what` (kAUStartIO)
///   or `input` (`MicSourceError.invalidInputFormat`, 0 Hz) on the mic start.
/// - `-LegatoFakeRefusalOnlyNonDefault YES`: the refusal applies only to sessions built for a policy
///   other than the default (so the fallback to `duckOthers` succeeds).
/// - `-LegatoFakeRefusalInForeground YES`: the refusal applies in the foreground too (default: only in
///   the background).
/// - `-LegatoFakeRefusalCount N`: only the first N refusable starts are refused, the rest succeed.
/// - `-LegatoAudioPolicy duckOthers|mixWithOthers|pauseOthers|duckMusicPauseSpoken`: the selected policy
///   (the experimental ones are switched on). With the fake engine, absent means the default policy.
///
/// Darwin notifications (see `installTriggers`): `toggle`, `interrupt`, `copy-last`, `foreground`,
/// `background`, `toggle-after-hop` (the press that repeats a `needsForeground` one after the hop).
/// Meetings (with `-LegatoFakeEngine`, the meeting uses the scripted engine and `E2EFakeMeetingMic`, a tone
/// that arrives in real time): `meeting-start`, `meeting-stop`, `meeting-mute`, `meeting-unmute`, `meeting-pause`, `meeting-resume`, `meeting-discard`,
/// `meeting-export` (writes what the share sheet would offer), `meeting-route-change` (AirPods connected),
/// and `interrupt-end` (the end of an interruption, with `shouldResume`).
/// - `-LegatoKeepAliveSeconds <n>`: sets the keep-alive setting (any number of seconds).
/// - `-LegatoFakeKeyboardApply YES|NO`: whether the fake keyboard types the streamed text into its
///   document and confirms it (default YES). NO leaves the final text unconfirmed.
///
/// - `-LegatoKeyboardHarness YES`: show the keyboard harness (the keyboard's UI over a text view in the
///   app) instead of the app's screens. Its command is `harness-mic` (a tap on the mic key).
///
/// URLs: `legato://toggle` calls `AppController.toggle()`; `legato://interrupt` posts the notification
/// the audio session sends on an interruption, so the real observer handles it.
///
/// The fake keyboard (`E2EFakeKeyboard`) stands in for the keyboard extension: it publishes presence,
/// sends requests, and applies the streamed text with the real `ProxyEditPlanner`. Commands
/// `kbd-visible`, `kbd-hidden`, `kbd-request-start|stop|end-keep-alive`, `kbd-hop-arm` (the mic key with no
/// lease: the arm request, then the URL), `kbd-hop-arm-url-first` (the URL, then the request),
/// `kbd-hop-start` (a start the host answered with `hop`, then its URL), `kbd-forged-url` (an arm URL no request backs).
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

    static let showsKeyboardHarness = UserDefaults.standard.bool(forKey: "LegatoKeyboardHarness")

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
        case pla, int, what, input

        /// `pla` / `int` fail the session activation, `what` / `input` the mic start.
        var isSessionStep: Bool { self == .pla || self == .int }

        /// 'pla' = `AVAudioSession.ErrorCode.cannotStartPlaying`, 'int' = `.cannotInterruptOthers`,
        /// 'what' = kAUStartIO, `input` = the input node reported 0 Hz.
        var error: any Error {
            switch self {
            case .pla: NSError(domain: NSOSStatusErrorDomain, code: 561_015_905)
            case .int: NSError(domain: NSOSStatusErrorDomain, code: 560_557_684)
            case .what: NSError(domain: NSOSStatusErrorDomain, code: 2_003_329_396)
            case .input: MicSourceError.invalidInputFormat
            }
        }
    }

    static let fakeRefusal: Refusal? = UserDefaults.standard.string(forKey: "LegatoFakeBackgroundRefusal").flatMap(Refusal.init)
    static let fakeRefusalOnlyNonDefault = launchFlag("LegatoFakeRefusalOnlyNonDefault") == true
    static let fakeRefusalInForeground = launchFlag("LegatoFakeRefusalInForeground") == true
    /// Refusals still to hand out; nil = unlimited.
    private static let refusalsLeft = Mutex<Int?>(
        UserDefaults.standard.object(forKey: "LegatoFakeRefusalCount") == nil
            ? nil : UserDefaults.standard.integer(forKey: "LegatoFakeRefusalCount"))

    /// The error a start should fail with now, when it is the session (`sessionStep`) or the mic step
    /// that is refused, for a session built for `policy`.
    static func refusal(sessionStep: Bool, policy: AudioPolicy) -> (any Error)? {
        guard let refusal = fakeRefusal, refusal.isSessionStep == sessionStep,
              fakeInBackground == true || fakeRefusalInForeground else { return nil }
        if fakeRefusalOnlyNonDefault && policy == .default { return nil }
        let allowed = refusalsLeft.withLock { left -> Bool in
            guard let n = left else { return true }
            guard n > 0 else { return false }
            left = n - 1
            return true
        }
        return allowed ? refusal.error : nil
    }

    static let fakePolicy: AudioPolicy? = UserDefaults.standard.string(forKey: "LegatoAudioPolicy").flatMap(AudioPolicy.init(rawValue:))

    /// A linger in whole seconds for the logs: -1 for indefinite.
    static func seconds(of linger: Linger) -> Int {
        switch linger {
        case .off: 0
        case .indefinite: -1
        case .duration(let d): Int(d.components.seconds)
        }
    }

    /// A session wired to the scripted engine, or nil when fake mode is off.
    @MainActor
    static func makeFakeSession(
        history: any HistoryStore, postProcessor: (any TranscriptPostProcessor)? = nil, policy: AudioPolicy, linger: Linger
    ) -> DictationSession? {
        guard let engine = fakeEngine else { return nil }
        log("session.make engine=\(engine.id) policy=\(policy.rawValue) lingerSeconds=\(seconds(of: linger))")
        return DictationSession(
            engine: engine,
            source: E2EFakeAudioSource(policy: policy),
            sessionControl: E2ENoopSessionControl(policy: policy),
            history: history,
            postProcessor: postProcessor,
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
        if let policy = fakePolicy {
            Settings.debugShowPauseOthers = true
            Settings.audioPolicy = policy
        } else if fakeEngine != nil {
            Settings.debugShowPauseOthers = false
            Settings.audioPolicy = .default
        }
        installTriggers()
        log("launch keepAliveSeconds=\(Settings.keepAliveSeconds) fakeEngine=\(fakeEngine != nil) fakeReadiness=\(String(describing: fakeReadiness)) forceTapToCopy=\(Settings.debugForceTapToCopy) fakeBackground=\(String(describing: fakeInBackground)) fakeOtherAudio=\(String(describing: fakeOtherAudioPlaying))")
    }
}

extension E2E {
    /// The meeting's audio in the simulator run: no AVAudioSession, a scripted tone for a microphone.
    @MainActor
    static var meetingAudio: MeetingAudioEnvironment {
        MeetingAudioEnvironment(
            activate: { _ in log("meeting.session.activate") },
            reactivate: { log("meeting.session.reactivate") },
            deactivate: { log("meeting.session.deactivate") },
            makeMic: { E2EFakeMeetingMic() })
    }
}

/// A microphone for a meeting: a 440 Hz tone in 100 ms chunks, delivered in real time, so the recording
/// has the length of the meeting. A new instance is a restarted engine.
final class E2EFakeMeetingMic: AudioSource, Sendable {
    /// The system took the microphone (the `interrupt` command): the tone stops until a fresh mic starts.
    static let taken = Mutex(false)

    private let task = Mutex<Task<Void, Never>?>(nil)

    func start(format: AudioFormatSpec) async throws -> AsyncStream<AudioChunk> {
        Self.taken.withLock { $0 = false }
        E2E.log("meeting.mic.start")
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let spec = AudioFormatSpec(sampleRate: 16_000, channelCount: 1)
        let producer = Task {
            var phase = 0.0
            while !Task.isCancelled {
                let samples = (0..<1_600).map { _ -> Float in
                    phase += 2 * Double.pi * 440 / 16_000
                    return Float(0.2 * sin(phase))
                }
                if !Self.taken.withLock({ $0 }) { continuation.yield(AudioChunk(samples: samples, format: spec)) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            continuation.finish()
        }
        task.withLock { $0 = producer }
        continuation.onTermination = { _ in producer.cancel() }
        return stream
    }

    func route() async throws -> AsyncStream<AudioChunk> { throw MicSourceError.notArmed }
    func detach() async {}

    func stop() async {
        E2E.log("meeting.mic.stop")
        let producer = task.withLock { t in defer { t = nil }; return t }
        producer?.cancel()
        await producer?.value
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
        if command.hasPrefix("harness-") {
            KeyboardHarnessModel.shared.run(command)
            return
        }
        switch command {
        case "toggle":
            _ = await toggle()
        case "interrupt":
            E2EFakeMeetingMic.taken.withLock { $0 = true }
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        case "interrupt-end":
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                    AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
                ])
        case "meeting-start":
            await meetings.start()
        case "meeting-stop":
            _ = await meetings.stop()
        case "meeting-mute":
            meetings.setManualMute(true)
        case "meeting-unmute":
            meetings.setManualMute(false)
        case "meeting-pause":
            meetings.setPaused(true)
        case "meeting-resume":
            meetings.setPaused(false)
        case "meeting-discard":
            await meetings.discard()
        case "meeting-route-change":
            NotificationCenter.default.post(
                name: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        case "meeting-export":
            await meetings.refresh()
            if let meeting = meetings.meetings.first { _ = await meetings.exportItems(for: meeting) }
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
        "toggle", "interrupt", "interrupt-end", "copy-last", "foreground", "background", "toggle-after-hop",
        "meeting-start", "meeting-stop", "meeting-mute", "meeting-unmute", "meeting-pause", "meeting-resume", "meeting-discard", "meeting-export", "meeting-route-change",
        "kbd-visible", "kbd-hidden", "kbd-request-start", "kbd-request-stop", "kbd-request-end-keep-alive",
        "kbd-hop-arm", "kbd-hop-start", "kbd-hop-arm-url-first", "kbd-forged-url",
        "harness-mic", "harness-mic-hop", "harness-type", "harness-numbers",
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
