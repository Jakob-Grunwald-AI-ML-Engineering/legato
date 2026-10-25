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

@MainActor @Observable
final class SessionController {
    static let shared = SessionController()

    private(set) var isActive = false
    private(set) var level: Float = 0
    private(set) var lastError: String?

    let dictation = Dictation()
    private let engine = AVAudioEngine()
    private let router = TapRouter()
    private var heartbeat: Task<Void, Never>?
    private var activity: Activity<SessionAttributes>?
    private var tokens: [NSObjectProtocol] = []
    private var darwin: [DarwinObserver] = []
    private var lastCommandSeq: Double = 0

    private func log(_ msg: String) { SpikeLog.write("app", msg) }

    private init() {
        Spike.defaults.set(false, forKey: Spike.Key.active)
        log("process launched (SessionController init)")
        observeSystem()
        observeDarwin()
    }

    // MARK: Start / stop

    func start(source: String) async throws {
        log("start requested by \(source); appState=\(UIApplication.shared.applicationState.rawValue) (0 active, 1 inactive, 2 background)")
        if isActive { log("start ignored: already active"); return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try s.setPreferredInput(mic)
            }
            try s.setActive(true)
            log("activated mixable; otherAudioPlaying=\(s.isOtherAudioPlaying) silenceHint=\(s.secondaryAudioShouldBeSilencedHint)")
            do {
                try startEngine()
            } catch {
                // Seen with Audible playing: kAUStartIO fails ('what') from the background while
                // mixable. Retry non-mixable, which interrupts the other app; stop() resumes it.
                log("mixable engine start failed (\(error)); retrying non-mixable")
                try? s.setActive(false)
                try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
                try s.setActive(true)
                try startEngine()
                log("non-mixable start ok; other audio interrupted")
            }
            isActive = true
            Spike.defaults.set(true, forKey: Spike.Key.active)
            startActivity()
            startHeartbeat()
            log("SESSION STARTED via \(source); route in=\(routeSummary(inputs: true)) out=\(routeSummary(inputs: false))")
        } catch {
            lastError = "\(error)"
            log("SESSION START FAILED via \(source): \(error)")
            throw error
        }
    }

    func stop(reason: String) async {
        log("SESSION STOP (\(reason))")
        heartbeat?.cancel(); heartbeat = nil
        if dictation.isRunning { await dictation.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
        level = 0
        Spike.defaults.set(false, forKey: Spike.Key.active)
        for a in Activity<SessionAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
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
            log("LIVE ACTIVITY REQUEST FAILED: \(error)")
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

    private func routeSummary(inputs: Bool) -> String {
        let r = AVAudioSession.sharedInstance().currentRoute
        return (inputs ? r.inputs : r.outputs).map { "\($0.portType.rawValue)" }.joined(separator: ",")
    }

    // MARK: Dictation commands from the keyboard

    private func observeDarwin() {
        darwin.append(DarwinObserver(name: Spike.Note.startSession) {
            Task { @MainActor in
                SessionController.shared.log("Darwin startSession received (process alive)")
                try? await SessionController.shared.start(source: "darwin")
            }
        })
        darwin.append(DarwinObserver(name: Spike.Note.command) {
            Task { @MainActor in await SessionController.shared.handleCommand() }
        })
    }

    private func handleCommand() async {
        let d = Spike.defaults
        let seq = d.double(forKey: Spike.Key.commandSeq)
        guard seq != lastCommandSeq else { return }
        lastCommandSeq = seq
        let cmd = d.string(forKey: Spike.Key.command) ?? ""
        log("command from keyboard: \(cmd)")
        switch cmd {
        case "start":
            if !isActive { try? await start(source: "darwin-dictate") }
            guard isActive else { dictation.publishError("session not running"); return }
            if d.bool(forKey: Spike.Key.pauseOthers) { setMixing(false, why: "dictation start") }
            await dictation.start(router: router, inputFormat: engine.inputNode.outputFormat(forBus: 0))
        case "stop":
            await dictation.stop()
            if d.bool(forKey: Spike.Key.pauseOthers) { setMixing(true, why: "dictation stop") }
        default: break
        }
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

    /// Non-mixable interrupts other audio (Audible pauses); going back to mixable deactivates with
    /// notifyOthersOnDeactivation first, so the interrupted app gets `shouldResume`.
    private func setMixing(_ mix: Bool, why: String) {
        let s = AVAudioSession.sharedInstance()
        log("setMixing(\(mix)) for \(why); otherAudioPlaying=\(s.isOtherAudioPlaying) silenceHint=\(s.secondaryAudioShouldBeSilencedHint)")
        do {
            var opts: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker]
            if mix {
                engine.stop()
                try s.setActive(false, options: .notifyOthersOnDeactivation)
                opts.insert(.mixWithOthers)
            }
            try s.setCategory(.playAndRecord, mode: .default, options: opts)
            try s.setActive(true)
            if !engine.isRunning { try startEngine() }
            log("setMixing(\(mix)) ok; engineRunning=\(engine.isRunning)")
        } catch {
            log("SETMIXING(\(mix)) FAILED: \(error)")
        }
    }

    private func restartEngine(why: String) {
        guard isActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try startEngine() }
            log("engine restart ok (\(why))")
        } catch {
            log("ENGINE RESTART FAILED (\(why)): \(error)")
        }
    }
}
