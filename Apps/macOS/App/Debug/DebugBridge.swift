#if LEGATO_INTERNAL
import AppKit
import Foundation
import LegatoAppServices
import LegatoDevHarness

@MainActor enum DebugBridge {
    typealias Command = BridgeCommand
    private static let harness = DevHarness(root: root)
    private static var started = false

    /// Shared with ctl.sh --target mac. Each explicitly isolated app may supply its own absolute root.
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["LEGATO_MAC_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legato/debug-bridge", isDirectory: true)
    }
    private static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        ["YES", "TRUE", "1"].contains((UserDefaults.standard.string(forKey: "LegatoDebugBridge") ?? "").uppercased())
        #endif
    }
    static func start() {
        guard !started, isEnabled else { return }
        // Register closures only: bootstrap is still initializing the singleton's composition.
        registerBuiltins()
        started = true
        harness.start()
    }
    static func emit(id: String, event: String, _ fields: [String: Any] = [:]) { harness.emit(id: id, event: event, fields) }
    private static func registerBuiltins() {
        harness.register("state") { _ in MacAppController.shared.debugState() }
        harness.register("set-setting") { command in
            guard command.args.count == 2 else { throw Usage.error("set-setting <key> <value>") }
            try MacAppController.shared.debugSetSetting(command.args[0], value: command.args[1])
            return ["key": command.args[0]]
        }
        for (name, action) in [("toggle", MacAppController.DebugControl.toggle), ("stop", .stop),
                               ("interrupt", .interrupt), ("hotkey-start", .start),
                               ("meeting-start", .meetingStart), ("meeting-stop", .meetingStop)] {
            harness.register(name) { command in
                try MacAppController.shared.debugControl(action, id: command.id)
                return ["accepted": true, "waitFor": "control.done"]
            }
        }
        harness.register("session-probe") { command in
            guard command.args.count <= 1, let mode = SessionProbeMode(rawValue: command.args.first ?? "foreground") else {
                throw Usage.error("session-probe [foreground] (iOS background modes are unavailable on Mac)")
            }
            guard let id = try SessionProbe.start(commandID: command.id, mode: mode,
                status: { DebugMessages.shared.setStatus($0) }, block: { DebugMessages.shared.setBlocking($0) },
                isBlocked: { DebugMessages.shared.blocking }, emit: { id, event, fields in emit(id: id, event: event, fields) }) else {
                throw SessionProbeError.busy
            }
            return ["accepted": true, "probeID": id.uuidString, "waitFor": "session.probe.done"]
        }
        harness.register("say") { command in
            guard let parsed = LegatoDevHarness.DebugMessages.parse(command.args, takesChoices: false) else { throw Usage.error("say <text>") }
            DebugMessages.shared.say(id: command.id, text: parsed.text)
            return nil
        }
        harness.register("ask") { command in
            guard let parsed = LegatoDevHarness.DebugMessages.parse(command.args, takesChoices: true) else {
                throw Usage.error("ask <text> <choice>... [--timeout s] [--sound]")
            }
            DebugMessages.shared.ask(id: command.id, text: parsed.text, choices: parsed.choices, timeout: parsed.timeout, sound: parsed.sound)
            return ["waitFor": "reply"]
        }
        harness.register("status") { command in
            guard command.args.count == 1 else { throw Usage.error("status <text>") }
            DebugMessages.shared.setStatus(command.args[0])
            return nil
        }
        harness.register("block") { command in
            guard command.args.count == 1, ["on", "off"].contains(command.args[0]) else { throw Usage.error("block on|off") }
            DebugMessages.shared.setBlocking(command.args[0] == "on")
            return ["blocking": DebugMessages.shared.blocking]
        }
        harness.register("clear") { _ in DebugMessages.shared.clear(); return nil }
        harness.register("foreground") { _ in NSApp.unhide(nil); NSApp.activate(); return nil }
        harness.register("background") { _ in NSApp.hide(nil); return nil }
    }
    enum Usage: Error, CustomStringConvertible {
        case error(String)
        var description: String { switch self { case .error(let text): text } }
    }
}
#endif
