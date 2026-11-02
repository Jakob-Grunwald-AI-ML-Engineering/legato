#if LEGATO_INTERNAL
import Foundation
import LegatoDevHarness
import LegatoAppServices
import AppKit

@MainActor enum DebugBridge {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["LEGATO_MAC_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return URL.cachesDirectory.appending(path: "Legato/debug-bridge", directoryHint: .isDirectory)
    }
    private static let harness = DevHarness(root: root)
    private static var started = false
    static func start() {
        guard !started else { return }
        #if !DEBUG
        guard UserDefaults.standard.bool(forKey: "LegatoDebugBridge") else { return }
        #endif
        started = true
        harness.register("state") { _ in
            #if DEBUG
            return MacAppController.shared.composer.debugState
            #else
            return ["status": MacAppController.shared.composer.status]
            #endif
        }
        #if DEBUG
        for name in ComposerSession.debugCommands {
            harness.register(name) { command in
                if name == "composer-debug-seed" { return try await MacAppController.shared.seedDebugComposer(command.args) }
                if name == "composer-debug-start" { return try await MacAppController.shared.startDebugComposer(command.args) }
                return try await MacAppController.shared.composer.debugControl(name, args: command.args)
            }
        }
        harness.register("composer-import-keys") { command in
            guard command.args == ["credentials.json"] else { throw Usage.invalid }
            return try ComposerSession.importDebugKeys(file: root.appending(path: "credentials.json"))
        }
        // Mac dictation hotkey without speech: a finalized line (or live partial) enters where Soniox lines do and
        // is cleaned and typed into the focused field for real. The first one begins a microphone-free session
        // (the field in front is captured then); `dictation-debug-stop` ends it.
        harness.register("dictation-debug-line") { command in
            guard command.args.count == 1 else { throw Usage.invalid }
            try await MacAppController.shared.dictation.debugLine(command.args[0])
            return MacAppController.shared.dictation.debugState
        }
        harness.register("dictation-debug-tail") { command in
            guard command.args.count <= 1 else { throw Usage.invalid }
            try await MacAppController.shared.dictation.debugTail(command.args.first ?? "")
            return MacAppController.shared.dictation.debugState
        }
        harness.register("dictation-debug-stop") { _ in
            await MacAppController.shared.dictation.debugStop()
            return MacAppController.shared.dictation.debugState
        }
        harness.register("dictation-toggle") { _ in
            MacAppController.shared.toggleDictation()
            try await Task.sleep(for: .milliseconds(300))
            return MacAppController.shared.dictation.debugState
        }
        harness.register("dictation-state") { _ in MacAppController.shared.dictation.debugState }
        // The next N take cleanups (default 1) fail twice, so the failed state is reachable without network faults.
        harness.register("dictation-debug-fail-take") { command in
            guard command.args.count <= 1, let count = command.args.first.map({ Int($0) }) ?? 1, count >= 0 else { throw Usage.invalid }
            MacAppController.shared.dictation.pipeline.debugFailTakes = count
            return MacAppController.shared.dictation.debugState
        }
        // The pill's Retry and Insert as-is buttons, without a click.
        harness.register("dictation-retry") { _ in
            await MacAppController.shared.dictation.pipeline.retry()
            return MacAppController.shared.dictation.debugState
        }
        harness.register("dictation-insert-raw") { _ in
            await MacAppController.shared.dictation.pipeline.insertRaw()
            try await Task.sleep(for: .milliseconds(300))
            return MacAppController.shared.dictation.debugState
        }
        #endif
        harness.register("toggle") { _ in MacAppController.shared.toggle(); return ["status": "starting"] }
        harness.register("stop") { _ in MacAppController.shared.stopComposer(); return ["status": "stopping"] }
        harness.register("composer-insert") { _ in MacAppController.shared.insertComposer(origin: .debugBridge); return nil }
        harness.register("composer-cancel") { _ in MacAppController.shared.cancelComposer(); return nil }
        harness.register("session-probe") { _ in try SessionProbe.start(); return nil }
        harness.register("say") { command in
            guard let parsed = LegatoDevHarness.DebugMessages.parse(command.args, takesChoices: false) else { throw Usage.invalid }
            DebugMessages.shared.say(id: command.id, text: parsed.text); return nil
        }
        harness.register("ask") { command in
            guard let parsed = LegatoDevHarness.DebugMessages.parse(command.args, takesChoices: true) else { throw Usage.invalid }
            DebugMessages.shared.ask(id: command.id, text: parsed.text, choices: parsed.choices, timeout: parsed.timeout, sound: parsed.sound)
            return ["waitFor": "reply"]
        }
        harness.register("status") { command in DebugMessages.shared.setStatus(command.args.first); return nil }
        harness.register("block") { command in DebugMessages.shared.setBlocking(command.args.first == "on"); return nil }
        harness.register("clear") { _ in DebugMessages.shared.clear(); return nil }
        harness.register("foreground") { _ in NSApp.unhide(nil); NSApp.activate(); return nil }
        harness.register("background") { _ in NSApp.hide(nil); return nil }
        harness.start()
    }
    static func emit(id: String, event: String, _ fields: [String: Any] = [:]) { harness.emit(id: id, event: event, fields) }
    enum Usage: Error { case invalid }
}
#endif
