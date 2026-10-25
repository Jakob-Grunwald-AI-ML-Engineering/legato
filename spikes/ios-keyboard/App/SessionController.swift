import ActivityKit
import AVFAudio
import Foundation
import Observation
import UIKit

/// Audio-thread side: computes the mic level and forwards buffers to the dictation sink while dictating.
final class TapRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: Float = 0
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    var level: Float { lock.withLock { _level } }
    func setSink(_ s: (@Sendable (AVAudioPCMBuffer) -> Void)?) { lock.withLock { sink = s } }

    func handle(_ buffer: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            rms = (sum / Float(buffer.frameLength)).squareRoot()
        }
        let db = 20 * log10(max(rms, 0.000_01))
        let norm = min(max((db + 60) / 60, 0), 1)
        let s = lock.withLock { () -> (@Sendable (AVAudioPCMBuffer) -> Void)? in
            _level = norm
            return sink
        }
        s?(buffer)
    }
}

enum DictationTarget: String, Sendable { case keyboard, scratch }
enum ToggleOutcome: Sendable { case started(DictationTarget), stopped, ignored }

@MainActor @Observable
final class SessionController {
    static let shared = SessionController()

    /// Always on: duck music, interrupt spoken audio (Audible), keep A2DP and speaker routing.
    static let dictationOptions: AVAudioSession.CategoryOptions =
        [.duckOthers, .interruptSpokenAudioAndMixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]

    private(set) var isActive = false
    private(set) var level: Float = 0
    private(set) var lastError: String?

    // Scratch screen state: dictated text streams into `scratchText` after `scratchPrefix`.
    var scratchVisible = false
    var scratchText = ""
    private var scratchPrefix = ""
    private var target: DictationTarget = .keyboard

    let dictation = Dictation()
    private let engine = AVAudioEngine()
    private let router = TapRouter()
    private var transitioning = false
    private var heartbeat: Task<Void, Never>?
    private var activity: Activity<SessionAttributes>?
    private var tokens: [NSObjectProtocol] = []
    private var darwin: [DarwinObserver] = []

    private func log(_ msg: String) { SpikeLog.write("app", msg) }

    private init() {
        Spike.defaults.set(false, forKey: Spike.Key.active)
        log("process launched (SessionController init)")
        dictation.onUpdate = { [weak self] text in self?.dictationText(text) }
        observeSystem()
        observeDarwin()
    }

    // MARK: Toggle

    /// The single entry point: Action Button, Control Center, Live Activity, keyboard and in-app UI.
    func toggle(source: String) async throws -> ToggleOutcome {
        logContext("TOGGLE source=\(source) isActive=\(isActive) transitioning=\(transitioning)")
        guard !transitioning else { log("toggle ignored: a start/stop is still in progress"); return .ignored }
        transitioning = true
        defer { transitioning = false }
        if isActive {
            await stopAll(source: source)
            return .stopped
        }
        return .started(try await startAll(source: source))
    }

    private func keyboardVisibleRecently() -> Bool {
        let d = Spike.defaults
        let visible = d.bool(forKey: Spike.Key.kbdVisible)
        let age = Date().timeIntervalSince1970 - d.double(forKey: Spike.Key.kbdVisibleAt)
        let recent = visible && age < 2.0
        log("keyboard visible=\(visible) visibleAge=\(String(format: "%.2f", age))s -> \(recent ? "KEYBOARD branch" : "SCRATCH branch")")
        return recent
    }

    private func startAll(source: String) async throws -> DictationTarget {
        let chosen: DictationTarget = keyboardVisibleRecently() ? .keyboard : .scratch
        let s = AVAudioSession.sharedInstance()
        do {
            engine.stop()
            try s.setCategory(.playAndRecord, mode: .default, options: Self.dictationOptions)
            logContext("category set")
            do {
                if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try s.setPreferredInput(mic)
                }
            } catch { log("setPreferredInput failed: \(describe(error))") }
            try s.setActive(true)
            logContext("session activated")
            // From the background this fails with kAUStartIO 'what' in a process the user launched,
            // and works in one the intent launched.
            try startEngine()
        } catch {
            lastError = describe(error)
            log("START FAILED (\(source)): \(describe(error))")
            engine.stop()
            do { try s.setActive(false, options: .notifyOthersOnDeactivation) } catch {
                log("cleanup setActive(false) failed: \(describe(error))")
            }
            throw error
        }
        isActive = true
        lastError = nil
        target = chosen
        Spike.defaults.set(true, forKey: Spike.Key.active)
        Spike.defaults.set(Date().timeIntervalSince1970, forKey: Spike.Key.dictId)
        Spike.defaults.set(chosen.rawValue, forKey: Spike.Key.dictTarget)
        if chosen == .scratch {
            scratchPrefix = scratchText.isEmpty || scratchText.hasSuffix(" ") || scratchText.hasSuffix("\n") ? scratchText : scratchText + " "
            scratchVisible = true
        }
        startActivity()
        startHeartbeat()
        log("ENGINE STARTED via \(source); target=\(chosen); route in=\(routeSummary(inputs: true)) out=\(routeSummary(inputs: false))")
        await dictation.start(router: router, inputFormat: engine.inputNode.outputFormat(forBus: 0))
        logContext("dictation started")
        return chosen
    }

    private func stopAll(source: String) async {
        log("STOP via \(source)")
        heartbeat?.cancel(); heartbeat = nil
        if dictation.isRunning { await dictation.stop() }
        for a in Activity<SessionAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            log("setActive(false, notifyOthersOnDeactivation) ok")
        } catch {
            log("setActive(false) FAILED: \(describe(error))")
        }
        isActive = false
        level = 0
        Spike.defaults.set(false, forKey: Spike.Key.active)
        logContext("stopped")
    }

    private func dictationText(_ text: String) {
        if target == .scratch { scratchText = scratchPrefix + text }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(router))
        engine.prepare()
        try engine.start()
    }

    /// Built outside the MainActor: a closure formed inside a @MainActor method inherits that
    /// isolation, and Swift 6 traps when AVFAudio calls it on the realtime thread.
    nonisolated private static func tapBlock(_ router: TapRouter) -> AVAudioNodeTapBlock {
        { buffer, _ in router.handle(buffer) }
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log("LIVE ACTIVITY NOT ENABLED (areActivitiesEnabled == false)")
            return
        }
        do {
            let a = try Activity.request(
                attributes: SessionAttributes(),
                content: .init(state: .init(startedAt: .now), staleDate: nil))
            activity = a
            log("Live Activity started id=\(a.id)")
            Task { [weak self] in
                for await state in a.activityStateUpdates {
                    self?.log("Live Activity state -> \(state)")
                }
            }
        } catch {
            log("LIVE ACTIVITY REQUEST FAILED: \(describe(error))")
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                guard let self else { return }
                let lvl = self.router.level
                self.level = lvl
                let d = Spike.defaults
                d.set(Date().timeIntervalSince1970, forKey: Spike.Key.heartbeat)
                d.set(lvl, forKey: Spike.Key.level)
                d.set(Int(ProcessInfo.processInfo.processIdentifier), forKey: Spike.Key.pid)
                n += 1
                if n % 10 == 1 {
                    self.log("heartbeat #\(n) level=\(String(format: "%.2f", lvl)) engineRunning=\(self.engine.isRunning) appState=\(UIApplication.shared.applicationState.rawValue)")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func logContext(_ tag: String) {
        let s = AVAudioSession.sharedInstance()
        log("\(tag): pid=\(ProcessInfo.processInfo.processIdentifier) appState=\(UIApplication.shared.applicationState.rawValue) (0 active, 1 inactive, 2 background) otherAudioPlaying=\(s.isOtherAudioPlaying) silenceHint=\(s.secondaryAudioShouldBeSilencedHint) category=\(s.category.rawValue) options=\(Self.optionNames(s.categoryOptions)) engineRunning=\(engine.isRunning)")
    }

    private static func optionNames(_ o: AVAudioSession.CategoryOptions) -> String {
        let all: [(AVAudioSession.CategoryOptions, String)] = [
            (.mixWithOthers, "mixWithOthers"), (.duckOthers, "duckOthers"),
            (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudio"), (.allowBluetoothHFP, "bluetoothHFP"),
            (.allowBluetoothA2DP, "bluetoothA2DP"), (.defaultToSpeaker, "defaultToSpeaker"), (.allowAirPlay, "airPlay"),
        ]
        let names = all.filter { o.contains($0.0) }.map(\.1)
        return "[\(names.joined(separator: ","))]"
    }

    private func routeSummary(inputs: Bool) -> String {
        let r = AVAudioSession.sharedInstance().currentRoute
        return (inputs ? r.inputs : r.outputs).map { "\($0.portType.rawValue)" }.joined(separator: ",")
    }

    // MARK: Fallback path: keyboard -> Darwin notification (only works while this process is alive)

    private func observeDarwin() {
        darwin.append(DarwinObserver(name: Spike.Note.toggle) {
            Task { @MainActor in
                SessionController.shared.log("Darwin toggle received (process alive)")
                do { _ = try await SessionController.shared.toggle(source: "keyboard-darwin-fallback") } catch {
                    SessionController.shared.log("darwin toggle failed: \(describe(error))")
                }
            }
        })
    }

    // MARK: Interruptions, route changes, lifecycle (all logged)

    private func observeSystem() {
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()

        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99
            let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt) ?? 99
            let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            MainActor.assumeIsolated { SessionController.shared.interruption(type: type, reason: reason, options: opts) }
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 99
            MainActor.assumeIsolated {
                SessionController.shared.log("route change reason=\(reason) in=\(SessionController.shared.routeSummary(inputs: true)) out=\(SessionController.shared.routeSummary(inputs: false))")
            }
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: s, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt) ?? 99
            MainActor.assumeIsolated { SessionController.shared.log("silenceSecondaryAudioHint type=\(type) (1 begin, 0 end)") }
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { _ in
            MainActor.assumeIsolated {
                SessionController.shared.log("MEDIA SERVICES RESET")
                SessionController.shared.restartEngine(why: "media services reset")
            }
        })
        tokens.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            MainActor.assumeIsolated {
                SessionController.shared.log("engine configuration change; running=\(SessionController.shared.engine.isRunning)")
                SessionController.shared.restartEngine(why: "configuration change")
            }
        })
        for (name, label) in [
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didReceiveMemoryWarningNotification, "MEMORY WARNING"),
            (UIApplication.willTerminateNotification, "willTerminate"),
        ] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SessionController.shared.log("lifecycle: \(label)") }
            })
        }
    }

    private func interruption(type: UInt, reason: UInt, options: UInt) {
        let t = type == AVAudioSession.InterruptionType.began.rawValue ? "BEGAN" : "ENDED"
        log("INTERRUPTION \(t) reason=\(reason) (1 appWasSuspended[deprecated], 2 builtInMicMuted, 4 routeDisconnected) shouldResume=\(options & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0)")
        if t == "ENDED" && isActive { restartEngine(why: "interruption ended") }
    }

    private func restartEngine(why: String) {
        guard isActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try startEngine() }
            log("engine restart ok (\(why))")
        } catch {
            log("ENGINE RESTART FAILED (\(why)): \(describe(error))")
        }
    }
}
