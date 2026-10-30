#if LEGATO_INTERNAL
import Foundation
import LegatoKeyboardCore
import LegatoDevHarness
import UIKit

typealias BridgeCommand = LegatoDevHarness.BridgeCommand

/// Device debug bridge: drives the app on a physical iPhone without taps (`scripts/device/ctl.sh`).
///
/// The host copies one JSON file per command into `Library/Caches/debug-bridge/inbox/` of the app's data
/// container (`xcrun devicectl device copy to`). The bridge polls that folder every 0.5 s while the process
/// is alive (iOS suspends a backgrounded process that holds no audio session or other background mode, and
/// polling pauses then), runs each command on the main actor, deletes the file and appends
/// `{ts, id, event, ...}` lines to `Library/Caches/debug-bridge/log.jsonl` (trimmed to the last lines at
/// start). The bridge never logs dictated text or setting values; `state` reports lengths and flags only.
/// At start it drops any commands left in the inbox (logged as `dropped`).
///
/// Debug builds start it at launch. Other `LEGATO_INTERNAL` (TestFlight) builds start it only with the
/// launch argument `-LegatoDebugBridge YES`.
///
/// Built-in commands: `ping`, `state`, `set-setting <key> <value>`, `commands`; in Debug builds also every
/// simulator e2e command (`E2E.commands`: toggle, interrupt, copy-last, result-insert, result-copy,
/// foreground, background, kbd-*, harness-*, meeting-* ...), routed through the same `runE2E` the
/// Darwin-notification triggers use. Other code adds commands with `DebugBridge.register(_:handler:)`.
@MainActor
enum DebugBridge {
    typealias Handler = DevHarness.Handler
    private static let harness = DevHarness(root: root)
    private static var started = false

    static let pollInterval = DevHarness.pollInterval

    static func register(_ name: String, handler: @escaping Handler) { harness.register(name, handler: handler) }

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("debug-bridge", isDirectory: true)
    }
    static var inbox: URL { harness.transport.inbox }
    static var logURL: URL { harness.transport.logURL }

    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        ["YES", "TRUE", "1"].contains((UserDefaults.standard.string(forKey: "LegatoDebugBridge") ?? "").uppercased())
        #endif
    }

    static func start() {
        guard !started, isEnabled else { return }
        // Register closures only: evaluating AppController.shared here would recurse into its initializer.
        registerBuiltins()
        started = true
        harness.start()
    }

    static func status(_ text: String?) { DebugMessages.shared.setStatus(text) }
    static func stop() { harness.stop(); started = false }
    static func drain() async { await harness.drain() }
    static func execute(_ command: BridgeCommand) async { await harness.execute(command) }
    static func emit(id: String, event: String, _ fields: [String: Any] = [:]) { harness.emit(id: id, event: event, fields) }

    // MARK: Built-ins

    private static func registerBuiltins() {
        register("state") { _ in state() }
        register("say") { command in
            guard let p = DebugMessages.parse(command.args, takesChoices: false) else { throw BridgeError.usage("say <text>") }
            DebugMessages.shared.say(id: command.id, text: p.text)
            return nil
        }
        register("ask") { command in
            guard let p = DebugMessages.parse(command.args, takesChoices: true) else {
                throw BridgeError.usage("ask <text> <choice1> [choice2 ...] [--timeout s] [--sound]")
            }
            DebugMessages.shared.ask(id: command.id, text: p.text, choices: p.choices, timeout: p.timeout, sound: p.sound)
            return ["waitFor": "reply"]
        }
        register("status") { command in
            guard let text = command.args.first else { throw BridgeError.usage("status <text>") }
            DebugMessages.shared.setStatus(text)
            return nil
        }
        register("overlay-selftest") { command in
            // Shows a card, then checks where touches land: on the card they must reach the overlay, elsewhere not.
            let messages = DebugMessages.shared
            messages.ask(id: command.id + "-selftest", text: "Overlay self-test", choices: ["OK"], timeout: nil, sound: false)
            try? await Task.sleep(for: .milliseconds(800))
            defer { messages.reply(id: command.id + "-selftest", choice: "selftest") }
            guard let rect = messages.firstRect else { throw BridgeError.usage("no overlay frame reported") }
            let onCard = messages.overlayHit(at: CGPoint(x: rect.midX, y: rect.midY))
            let outsidePoint = CGPoint(x: rect.midX, y: rect.maxY + 200)
            let wasBlocking = messages.blocking
            messages.setBlocking(false)
            let outside = messages.overlayHit(at: outsidePoint)
            messages.setBlocking(true)
            let outsideBlocked = messages.overlayHit(at: outsidePoint)
            messages.setBlocking(wasBlocking)
            let result: [String: Any] = ["onCardHits": onCard, "outsideHits": outside, "outsideHitsWhileBlocking": outsideBlocked]
            guard onCard, !outside, outsideBlocked else { throw BridgeError.usage("overlay hit test wrong: \(result)") }
            return result
        }
        register("block") { command in
            guard let arg = command.args.first, ["on", "off"].contains(arg) else { throw BridgeError.usage("block on|off") }
            DebugMessages.shared.setBlocking(arg == "on")
            return ["blocking": arg == "on"]
        }
        register("clear") { _ in DebugMessages.shared.clear(); return nil }
        register("set-setting") { command in
            guard command.args.count == 2 else { throw BridgeError.usage("set-setting <key> <value>") }
            let key = command.args[0]
            guard settingKeys.contains(key) else { throw BridgeError.usage("key not allowed; one of \(settingKeys.sorted())") }
            AppGroup.defaults.set(parse(command.args[1]), forKey: key)
            return ["key": key]
        }
        #if DEBUG
        for name in E2E.commands {
            register(name) { command in
                await AppController.shared.runE2E(command.command)
                return nil
            }
        }
        #else
        register("toggle") { _ in _ = await AppController.shared.toggle(); return nil }
        register("copy-last") { _ in await AppController.shared.handle(DictationAttributes.copyLastURL); return nil }
        register("result-insert") { _ in await AppController.shared.insertResult(); return nil }
        register("result-copy") { _ in await AppController.shared.copyResult(); return nil }
        #endif
    }

    /// The app's own settings keys; `set-setting` refuses anything else (the App Group also holds link state).
    static let settingKeys: Set<String> = [
        "audioPolicy", "keepAliveSeconds", "keepAliveChoicesVersion", "keepSessionActiveBetweenRuns",
        "debugShowPauseOthers", "debugForceTapToCopy",
        KeyboardPreferences.hapticsKey, KeyboardPreferences.clicksKey, KeyboardPreferences.stripKey,
        KeyboardPreferences.stripHeightKey, AutoFillHandoff.preferenceKey,
    ]

    /// `true`/`false` become Bool, whole numbers Int, other numbers Double, the rest String.
    static func parse(_ text: String) -> Any {
        switch text.lowercased() {
        case "true", "yes": return true
        case "false", "no": return false
        default: break
        }
        if let i = Int(text) { return i }
        if let d = Double(text) { return d }
        return text
    }

    private static func state() -> [String: Any] {
        let app = AppController.shared
        let uiState: String
        switch UIApplication.shared.applicationState {
        case .active: uiState = "active"
        case .inactive: uiState = "inactive"
        case .background: uiState = "background"
        @unknown default: uiState = "unknown"
        }
        var out: [String: Any] = [
            "app": uiState,
            "isDictating": app.isDictating,
            "keyboardRunActive": app.keyboardRunActive,
            "showsKeyboardHop": app.showsKeyboardHop,
            "hopState": String(describing: app.keyboardHopState),
            "micReadyUntil": app.micReadyUntil.map { $0.bridgeTimestamp } ?? NSNull(),
            "recognitionPreparing": app.recognitionPreparing,
            "recognitionFailure": app.recognitionFailure ?? NSNull(),
            "armFailure": app.armFailure ?? NSNull(),
            "lastTranscriptChars": app.lastTranscript?.count ?? 0,
            "readiness": [
                "micGranted": app.status.micGranted, "micDenied": app.status.micDenied,
                "activitiesEnabled": app.status.activitiesEnabled, "assetsInstalled": app.status.assetsInstalled,
                "isReady": app.status.isReady,
            ],
            "settings": [
                "audioPolicy": Settings.audioPolicy.rawValue,
                "keepAliveSeconds": Settings.keepAliveSeconds,
                "keepSessionActiveBetweenRuns": Settings.keepSessionActiveBetweenRuns,
                "debugShowPauseOthers": Settings.debugShowPauseOthers,
                "debugForceTapToCopy": Settings.debugForceTapToCopy,
            ],
        ]
        #if DEBUG
        out["fakeInBackground"] = E2E.fakeInBackground.map { $0 as Any } ?? NSNull()
        out["fakeEngine"] = E2E.fakeEngine != nil
        #endif
        return out
    }

    enum BridgeError: Error { case usage(String) }
}

private extension Date {
    var bridgeTimestamp: String { formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true).timeZone(separator: .omitted)) }
}
#endif
