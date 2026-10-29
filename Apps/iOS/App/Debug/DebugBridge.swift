#if LEGATO_INTERNAL
import Foundation
import LegatoKeyboardCore
import UIKit
import os

/// A command file the host drops into the inbox: `{"id": "...", "command": "...", "args": ["..."]}`.
struct BridgeCommand: Decodable, Equatable {
    var id: String
    var command: String
    var args: [String] = []

    init(id: String, command: String, args: [String] = []) {
        self.id = id
        self.command = command
        self.args = args
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    }

    private enum CodingKeys: String, CodingKey { case id, command, args }

    static func decode(_ data: Data) -> BridgeCommand? { try? JSONDecoder().decode(BridgeCommand.self, from: data) }
}

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
    typealias Handler = @MainActor (BridgeCommand) async throws -> [String: Any]?

    private static var handlers: [String: Handler] = [:]
    private static var task: Task<Void, Never>?
    private static var badFiles: [String: Int] = [:]
    private static let logger = Logger(subsystem: "de.gruenwald.legato", category: "debug-bridge")

    static let pollInterval: Duration = .milliseconds(500)

    /// Adds (or replaces) a command.
    static func register(_ name: String, handler: @escaping Handler) {
        handlers[name] = handler
    }

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("debug-bridge", isDirectory: true)
    }
    static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    static var logURL: URL { root.appendingPathComponent("log.jsonl") }

    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        ["YES", "TRUE", "1"].contains((UserDefaults.standard.string(forKey: "LegatoDebugBridge") ?? "").uppercased())
        #endif
    }

    static func start() {
        guard task == nil, isEnabled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stale = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for file in stale { try? fm.removeItem(at: file) }
        trimLog()
        registerBuiltins()
        emit(id: "-", event: "started", ["dropped": stale.count, "pid": ProcessInfo.processInfo.processIdentifier, "commands": handlers.keys.sorted()])
        task = Task { @MainActor in
            while !Task.isCancelled {
                await drain()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// Keeps the last `keepLines` lines once the log passes twice that.
    private static func trimLog(keepLines: Int = 1000) {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > keepLines * 2 else { return }
        try? (lines.suffix(keepLines).joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }

    static func stop() {
        task?.cancel()
        task = nil
    }

    /// Runs every command file currently in the inbox, oldest name first.
    static func drain() async {
        let files = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        badFiles = badFiles.filter { name, _ in files.contains { $0.lastPathComponent == name } }
        for file in files {
            guard let data = try? Data(contentsOf: file), let command = BridgeCommand.decode(data) else {
                // A copy may still be in flight: give it three polls before calling it garbage.
                let n = (badFiles[file.lastPathComponent] ?? 0) + 1
                badFiles[file.lastPathComponent] = n
                if n >= 3 {
                    emit(id: file.deletingPathExtension().lastPathComponent, event: "error", ["message": "undecodable command file"])
                    try? FileManager.default.removeItem(at: file)
                    badFiles[file.lastPathComponent] = nil
                }
                continue
            }
            try? FileManager.default.removeItem(at: file)
            await execute(command)
        }
    }

    static func execute(_ command: BridgeCommand) async {
        emit(id: command.id, event: "received", ["command": command.command])
        guard let handler = handlers[command.command] else {
            emit(id: command.id, event: "error", ["message": "unknown command \(command.command)"])
            return
        }
        do {
            var fields = try await handler(command) ?? [:]
            fields["command"] = command.command
            emit(id: command.id, event: "done", fields)
        } catch {
            emit(id: command.id, event: "error", ["command": command.command, "message": String(describing: error)])
        }
    }

    /// Appends one JSON line to the log.
    static func emit(id: String, event: String, _ fields: [String: Any] = [:]) {
        var line = fields
        line["ts"] = Date().bridgeTimestamp
        line["id"] = id
        line["event"] = event
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // MARK: Built-ins

    private static func registerBuiltins() {
        register("ping") { _ in ["pong": true] }
        register("commands") { _ in ["commands": handlers.keys.sorted()] }
        register("state") { _ in state() }
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
