import AppKit
import ApplicationServices
import Foundation
import LegatoAppleSpeech
import LegatoAudio
import LegatoCore
import LegatoMac
import Observation
import os

/// The composition root: wires the hotkey, the dictation session, the field writer, the HUD and
/// the paste/copy fallback together. All work happens on the main actor.
///
/// Hotkey events go through `HotkeyGesture`; its actions (and engine aborts) are queued and run one
/// at a time, so a start, a stop and the finish after it can never overlap.
@MainActor @Observable
final class MacAppController {
    static let shared = MacAppController()
    static let onboardingWindowID = "onboarding"

    private static let log = Logger(subsystem: "de.gruenwald.legato", category: "mac")

    enum Phase: Equatable { case idle, preparing, listening, finishing }

    private(set) var phase = Phase.idle
    /// The newest history entries (20), newest first.
    private(set) var recent: [DictationEntry] = []
    /// Bumped to ask the UI to show the onboarding window.
    private(set) var onboardingRequests = 0
    private(set) var isRecordingHotkey = false
    private(set) var recordingPreview: String?
    /// A hotkey press found something unfinished in setup while the user was in another app:
    /// the menu-bar icon shows a warning until the onboarding window is opened.
    private(set) var setupAttention = false

    @ObservationIgnored let settings = MacSettings()
    @ObservationIgnored let permissions: Permissions
    @ObservationIgnored let loginItem = LoginItem()
    @ObservationIgnored private let engine = AppleSpeechEngine()
    @ObservationIgnored private let history: JSONLHistoryStore
    @ObservationIgnored private let session: DictationSession
    @ObservationIgnored private let hud = HUDPanelController()
    @ObservationIgnored private let paster = PasteService()
    @ObservationIgnored private let tap = HotkeyTap()
    @ObservationIgnored private var gesture: HotkeyGesture
    @ObservationIgnored private var recorder = HotkeyRecorderLogic()
    @ObservationIgnored private var commands: AsyncStream<Command>.Continuation?
    @ObservationIgnored private var activeRun: Run?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    /// Fires `gesture.tick` when a press has been held alone for the arm delay.
    @ObservationIgnored private var armTask: Task<Void, Never>?
    @ObservationIgnored private var triggerPressedAt: TimeInterval?
    @ObservationIgnored private var bootstrapped = false

    private enum Command: Sendable {
        case start, stop, cancel
        case aborted(UUID)
    }

    /// One dictation from key press to delivery.
    private final class Run {
        let id = UUID()
        let writer: FieldWriter
        let targetPID: pid_t?
        let startedAt = Date()
        /// The field was (or could not be ruled out as) a secure one: never typed or pasted into.
        let secureField: Bool
        /// Everything the engine committed, as the edit pump saw it.
        var committed = ""

        init(writer: FieldWriter, targetPID: pid_t?, secureField: Bool) {
            self.writer = writer
            self.targetPID = targetPID
            self.secureField = secureField
        }
    }

    private init() {
        let support = URL.applicationSupportDirectory.appending(path: "Legato", directoryHint: .isDirectory)
        let history = JSONLHistoryStore(fileURL: support.appending(path: "history.jsonl"))
        self.history = history
        permissions = Permissions(engine: engine)
        gesture = HotkeyGesture(mode: settings.gestureMode)
        session = DictationSession(
            engine: engine,
            source: MicSource(),
            sessionControl: AudioSessionController(),
            history: history,
            linger: .zero)
    }

    // MARK: Derived state for the UI

    var isDictating: Bool { phase != .idle }

    var permissionsDone: Bool {
        permissions.micGranted && permissions.accessibility && permissions.hotkeyTapActive
    }

    /// Something the dictation flow needs is missing.
    var needsSetup: Bool {
        !permissionsDone || settings.hotkey == nil || !permissions.modelInstalled
    }

    var statusText: String {
        switch phase {
        case .preparing: return "Starting…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        case .idle:
            guard let hotkey = settings.hotkey else { return "Choose a hotkey" }
            if needsSetup { return "Setup incomplete" }
            return "Ready · \(hotkey.displayName)"
        }
    }

    var statusSymbol: String {
        switch phase {
        case .idle: needsSetup ? "exclamationmark.triangle" : "mic"
        default: "waveform"
        }
    }

    // MARK: Launch

    /// Starts the hotkey, the edit pump and the permission poll. Called once at launch.
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.perform(command)
            }
        }
        Task { [weak self, edits = session.edits] in
            for await edit in edits { self?.apply(edit) }
        }
        Task { [weak self, samples = tap.samples] in
            for await sample in samples { self?.handle(sample) }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.pollSystem()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task { [weak self] in
            await self?.refreshRecent()
            await self?.permissions.refreshModel()
            self?.pollSystem()
            if self?.needsSetup == true { self?.requestOnboarding() }
        }
    }

    func requestOnboarding() {
        setupAttention = false
        onboardingRequests += 1
    }

    /// Something is missing, discovered from a hotkey press: do not pull the user out of the app
    /// they are in. Show a toast and flag the menu-bar item instead.
    private func flagSetup() {
        setupAttention = true
        hud.show(toast: "Open Legato to finish setup")
    }

    /// The hotkey spec's caution, if any, for the recorder UI.
    var hotkeyWarning: HotkeySpec.Warning? { settings.hotkey?.warning }

    /// Permissions can change at any time: keep the event tap alive and in step with them.
    private func pollSystem() {
        permissions.refresh()
        if tap.isActive, !tap.isEnabled {
            tap.stop() // revoked behind our back; try again below
            resetGesture()
        }
        // Only try once a grant exists: creating the tap without one makes macOS show a prompt.
        if !tap.isActive, permissions.accessibility || CGPreflightListenEventAccess() {
            resetGesture() // key events while there was no tap are gone
            tap.start()
        }
        if permissions.hotkeyTapActive != tap.isActive { permissions.hotkeyTapActive = tap.isActive }
        if setupAttention, !needsSetup { setupAttention = false }
        releaseStuckTrigger()
    }

    // MARK: History

    func refreshRecent() async {
        recent = (try? await history.recent(limit: 20)) ?? []
    }

    func copy(_ entry: DictationEntry) {
        paster.copy(entry.text)
    }

    func delete(_ entry: DictationEntry) {
        Task {
            try? await history.delete(id: entry.id)
            await refreshRecent()
        }
    }

    // MARK: Hotkey recording

    func beginRecording() {
        guard tap.isActive else {
            hud.show(toast: "Grant Accessibility access first.")
            return
        }
        resetGesture()
        recorder = HotkeyRecorderLogic()
        recordingPreview = nil
        isRecordingHotkey = true
    }

    func cancelRecording() {
        isRecordingHotkey = false
        recordingPreview = nil
    }

    // MARK: Key events

    private func handle(_ sample: TapSample) {
        guard let event = sample.event else {
            resetGesture() // the tap was disabled for a while: held keys can no longer be trusted
            return
        }
        if isRecordingHotkey {
            switch recorder.feed(event) {
            case .none: break
            case .preview(let text): recordingPreview = text
            case .captured(let spec):
                settings.hotkey = spec
                cancelRecording()
            case .cancelled: cancelRecording()
            }
            return
        }
        guard let hotkey = settings.hotkey, let trigger = hotkey.triggerEvent(for: event) else { return }
        // A timer that fired late must not reorder things: bring the gesture up to this event's time first.
        dispatch(gesture.tick(at: sample.time))
        if trigger == .pressed, phase == .idle, gesture.mode != settings.gestureMode {
            gesture = HotkeyGesture(mode: settings.gestureMode)
        }
        if trigger == .pressed, case .modifier = hotkey, gesture.isTriggerDown {
            // A lone modifier cannot go down twice: its release was lost. Close that press first.
            dispatch(gesture.released(at: sample.time))
        }
        switch trigger {
        case .pressed:
            triggerPressedAt = sample.time
            dispatch(gesture.pressed(at: sample.time))
        case .released:
            triggerPressedAt = nil
            dispatch(gesture.released(at: sample.time))
        case .otherKeyDown:
            dispatch(gesture.otherKeyDown())
        }
        scheduleArm()
    }

    private func dispatch(_ action: HotkeyGesture.Action?) {
        switch action {
        case .start: commands?.yield(.start)
        case .stop: commands?.yield(.stop)
        case .cancel: commands?.yield(.cancel)
        case nil: break
        }
    }

    /// Wakes up when the pressed trigger has been held alone long enough to start a run.
    private func scheduleArm() {
        armTask?.cancel()
        armTask = nil
        guard let deadline = gesture.armDeadline else { return }
        armTask = Task { [weak self] in
            let wait = deadline - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.dispatch(self.gesture.tick(at: max(ProcessInfo.processInfo.systemUptime, deadline)))
        }
    }

    /// Key events were lost (tap restarted or re-enabled): forget any press or latch in progress.
    private func resetGesture() {
        armTask?.cancel()
        armTask = nil
        triggerPressedAt = nil
        gesture.reset()
    }

    /// Safety net for a lost release of a lone-modifier trigger: if the keyboard says the modifier
    /// has been up for a while but the gesture still thinks it is held, close the press.
    private func releaseStuckTrigger() {
        guard case .modifier(let key)? = settings.hotkey, gesture.isTriggerDown,
              let pressedAt = triggerPressedAt, ProcessInfo.processInfo.systemUptime - pressedAt > 1.5
        else { return }
        let raw = CGEventSource.flagsState(.combinedSessionState).rawValue
        let flags = ModifierFlags(rawValue: UInt(truncatingIfNeeded: raw) & 0xFFFF_0000)
        guard !flags.contains(key.flag) else { return }
        triggerPressedAt = nil
        dispatch(gesture.released(at: ProcessInfo.processInfo.systemUptime))
        scheduleArm()
    }

    // MARK: Commands

    private func perform(_ command: Command) async {
        switch command {
        case .start: await startRun()
        case .stop: await finishRun(discard: false)
        case .cancel: await finishRun(discard: true)
        case .aborted(let id): await abortRun(id: id)
        }
    }

    private func startRun() async {
        guard activeRun == nil else {
            // A start while a run is already going means the gesture lost track of it (events were
            // lost): treat the press as the stop tap.
            gesture.runEnded()
            if phase == .listening { await finishRun(discard: false) }
            return
        }
        guard permissions.micGranted else {
            gesture.runEnded()
            flagSetup()
            return
        }

        let target: AXTextTarget?
        var secureField = false
        switch AXTextTarget.captureFocused() {
        case .target(let focused): target = focused
        case .none: target = nil
        case .secure:
            target = nil
            secureField = true
        }
        let run = Run(
            writer: FieldWriter(target: target, mode: settings.insertionMode),
            targetPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            secureField: secureField)
        activeRun = run
        phase = .preparing
        hud.beginRun()
        do {
            try await session.start()
        } catch {
            activeRun = nil
            phase = .idle
            gesture.runEnded()
            if case DictationError.assetsNotInstalled = error {
                hud.endRun()
                Task { await permissions.refreshModel() }
                flagSetup()
            } else if case DictationError.cancelled = error {
                hud.endRun()
            } else {
                Self.log.error("start failed: \(Self.describe(error), privacy: .public)")
                hud.endRun(toast: "Could not start: \(error.localizedDescription)")
            }
            return
        }
        phase = .listening
        hud.setPhase(.listening)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                // The session ends a run on its own when the engine stream fails.
                if self.session.runState == .idle {
                    self.commands?.yield(.aborted(run.id))
                    return
                }
            }
        }
    }

    /// Ends the run. `discard` is the chord cancel: nothing is delivered and nothing is saved.
    private func finishRun(discard: Bool) async {
        guard let run = activeRun, phase == .listening || phase == .preparing else { return }
        monitor?.cancel()
        phase = .finishing
        hud.setPhase(.finishing)

        var entry: DictationEntry?
        var failure: (any Error)?
        do {
            entry = try await session.stop()
        } catch {
            failure = error
        }

        if discard {
            if let entry { try? await history.delete(id: entry.id) }
            // Cancelled with no text kept: take back what was typed, if it is provably still ours.
            let toast = run.writer.revert() == .leftInPlace
                ? "Cancelled. Text already typed was left in place."
                : nil
            conclude(run, toast: toast)
            return
        }
        // `session.stop()` has yielded every edit; let the pump hand them to the writer.
        await drainEdits(of: run, expecting: entry?.text)

        if let failure {
            Self.log.error("stop failed: \(Self.describe(failure), privacy: .public)")
            await deliver(run, finalText: nil, salvage: true, notice: "Dictation stopped early.")
        } else {
            await deliver(run, finalText: entry?.text ?? "", salvage: false, notice: nil)
        }
    }

    /// The engine ended the run by itself: deliver what was heard.
    private func abortRun(id: UUID) async {
        guard let run = activeRun, run.id == id, phase == .listening else { return }
        monitor?.cancel()
        phase = .finishing
        hud.setPhase(.finishing)
        gesture.runEnded()
        if let error = session.lastError { Self.log.error("run aborted: \(Self.describe(error), privacy: .public)") }
        await drainEdits(of: run, expecting: nil)
        await deliver(run, finalText: nil, salvage: true, notice: "Dictation stopped early.")
    }

    /// Finishes the writer and routes whatever the field is missing.
    /// `salvage`: the session did not save an entry (it aborted), so the run's own text goes to history.
    private func deliver(_ run: Run, finalText: String?, salvage: Bool, notice: String?) async {
        let action = run.writer.finish(finalText: finalText)
        var toast = notice
        switch action {
        case .done:
            break
        case .copy(let rest):
            paster.copy(rest)
            toast = "Copied the rest — paste with ⌘V."
        case .paste(let full):
            let outcome = await paster.paste(
                full,
                restoreClipboard: settings.restoreClipboard,
                targetPID: run.targetPID,
                secureField: run.secureField)
            if case .copied(let reason) = outcome { toast = reason.toast }
        }
        if salvage {
            let saved = (finalText ?? run.committed).trimmingCharacters(in: .whitespacesAndNewlines)
            if !saved.isEmpty {
                let entry = DictationEntry(
                    date: run.startedAt,
                    text: saved,
                    localeIdentifier: Locale.current.identifier,
                    engineID: engine.id,
                    duration: Date().timeIntervalSince(run.startedAt))
                try? await history.append(entry)
            }
        }
        conclude(run, toast: toast)
    }

    /// Errors are logged by type and code only: their descriptions could echo dictated text.
    private static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(type(of: error)) \(ns.domain) \(ns.code)"
    }

    private func conclude(_ run: Run, toast: String?) {
        activeRun = nil
        phase = .idle
        hud.endRun(toast: toast)
        Task { await refreshRecent() }
    }

    /// Waits (briefly) until the pump has applied the run's last commit to the writer.
    private func drainEdits(of run: Run, expecting text: String?) async {
        guard let text else {
            await Task.yield()
            return
        }
        var tries = 0
        while run.committed.trimmingCharacters(in: .whitespacesAndNewlines) != text, tries < 50 {
            try? await Task.sleep(for: .milliseconds(10))
            tries += 1
        }
    }

    // MARK: Edits

    private func apply(_ edit: TranscriptEdit) {
        guard let run = activeRun else { return }
        run.writer.apply(edit)
        switch edit {
        case .commit(let delta):
            run.committed += delta
            hud.model.committed += delta
        case .replaceVolatile(let text):
            hud.model.volatile = text
        }
    }
}
