#if LEGATO_INTERNAL
import Foundation
import LegatoDevHarness
import LegatoAppServices
import LegatoMac
import AppKit
import ApplicationServices

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
        harness.register("state") { _ in MacAppController.shared.dictation.debugState }
        #if DEBUG
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
        // The cancel chord's effect without the hotkey: drops the unsent take and ends the session, nothing typed.
        harness.register("dictation-cancel") { _ in
            await MacAppController.shared.dictation.cancel()
            return MacAppController.shared.dictation.debugState
        }
        harness.register("dictation-state") { _ in MacAppController.shared.dictation.debugState }
        // The next N take cleanups (default 1) fail twice, so the failed state is reachable without network faults.
        harness.register("dictation-debug-fail-take") { command in
            guard command.args.count <= 1, let count = command.args.first.map({ Int($0) }) ?? 1, count >= 0 else { throw Usage.invalid }
            MacAppController.shared.dictation.pipeline.debugFailTakes = count
            return MacAppController.shared.dictation.debugState
        }
        // Scripted streaming cleaner for the next take cleanups: `<chunkMs> [failAfterChunks]` (first stream only fails),
        // `<chunkMs> reply <text>` (every take streams that text), or `off`.
        harness.register("dictation-debug-stream") { command in
            if command.args == ["off"] { MacAppController.shared.dictation.pipeline.debugStreamCleaner = nil; return MacAppController.shared.dictation.debugState }
            if command.args.count >= 3, command.args[1] == "reply", let ms = Int(command.args[0]), ms >= 0 {
                MacAppController.shared.dictation.pipeline.debugStreamCleaner = DebugStreamingCleaner(chunkMilliseconds: ms, reply: command.args[2...].joined(separator: " "))
                return MacAppController.shared.dictation.debugState
            }
            guard (1...2).contains(command.args.count), let ms = Int(command.args[0]), ms >= 0 else { throw Usage.invalid }
            let fail = command.args.count == 2 ? Int(command.args[1]) : nil
            if command.args.count == 2, fail == nil { throw Usage.invalid }
            MacAppController.shared.dictation.pipeline.debugStreamCleaner = DebugStreamingCleaner(chunkMilliseconds: ms, failAfterChunks: fail)
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
        harness.register("magic-toggle") { _ in
            MacAppController.shared.toggleMagic()
            try await Task.sleep(for: .milliseconds(300))
            return MacAppController.shared.dictation.debugState
        }
        harness.register("magic-undo") { _ in MacAppController.shared.instructionAction(.undo); return nil }
        harness.register("magic-accept") { _ in MacAppController.shared.instructionAction(.accept); return nil }
        harness.register("magic-dismiss") { _ in MacAppController.shared.instructionAction(.dismiss); return nil }
        harness.register("magic-state") { _ in MacAppController.shared.dictation.instruction.debugState }
        harness.register("field-fixture-state") { _ in
            let app = MacAppController.shared
            await AXTextTarget.prepareFocused()
            let capture: String
            switch AXTextTarget.captureFocused() {
            case .target(let target): capture = target.editsInPlace ? "readable" : target.typesKeys ? "readable-keys" : "readable-no-writes"
            case .none: capture = "unavailable"
            case .password: capture = "password"
            }
            let panel = app.fieldEditor.panel
            return ["capture": capture, "captureNote": AXTextTarget.lastCaptureNote, "offline": MacDictationSession.offlineFixture,
                    "axTrusted": AXIsProcessTrusted(),
                    "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                    "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                    "magicHotkey": app.settings.hotkey?.displayName ?? "", "dictationHotkey": app.settings.dictationHotkey?.displayName ?? "",
                    "send": app.settings.dictationSend.rawValue, "hotkeysEnabled": app.permissions.hotkeyTapActive,
                    "panelMode": PanelDictationSetting.mode().rawValue, "panelActive": panel.active,
                    "panelText": panel.take.text, "panelInserting": panel.inserting]
        }
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
