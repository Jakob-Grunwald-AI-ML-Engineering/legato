#if DEBUG
import LegatoKeyboardCore
import SwiftUI
import UIKit

/// The keyboard's UI inside the app, for the simulator end-to-end run (`-LegatoKeyboardHarness YES`):
/// the real `KeyboardController`, `KeyboardRootView`, `TypingModel` and `MicKey` over a `UITextView`-backed
/// document, talking to the app's own dictation through the real App Group values and Darwin notes. The
/// extension itself can't be loaded headless, so this is the closest drive of the keyboard side.
/// Debug builds only.
///
/// Launch arguments (all optional):
/// - `-LegatoHarnessAppearance dark|light`: the field's keyboard appearance (and the app's color scheme).
/// - `-LegatoHarnessKeyboardType email|url|number|phone|decimal|numbers`: the field's keyboard type.
/// - `-LegatoHarnessReturn send|go|search|next|done|join`: the field's return key.
/// - `-LegatoHarnessAutocap NO`: no auto-capitalization (lowercase letters, to compare with the system keyboard).
/// - `-LegatoHarnessSuggestions a,b,c`: fill the word row's slots, whatever is typed.
/// - `-LegatoHarnessGlobe YES`: show the globe key.
/// - `-LegatoHarnessStrip YES`: the compact strip (word row above the strip's row) at its requested height.
/// - `-LegatoHarnessLandscape YES`: lay the keyboard out 874 pt wide (landscape height), turned a quarter
///   turn so it fits the portrait screen (the screenshot is turned back).
///
/// - `-LegatoHarnessSystemField YES`: no harness at all: a plain text field that the system gives the real
///   Legato keyboard extension to (pins the field to the extension's input mode, see `SystemFieldHost`),
///   to look at the extension itself. Logs `systemfield modes=...` and the keyboard's own
///   `kbd.geometry` lines (see `KeyboardViewController`).
/// - `-LegatoHarnessContentType username|password|newPassword|oneTimeCode|emailAddress|URL|none`:
///   initial system field's semantic type. Other real fields below it cover credentials and ordinary prose.
/// - `-LegatoHarnessSecure YES`: initial system field is secure (iOS supplies its native keyboard).
/// - `-LegatoHarnessSingleField YES`: omit sibling fields to isolate host credential-form heuristics.
/// - `-LegatoHarnessUnpinKeyboard YES`: release the Legato input-mode pin after initial focus, so native
///   keyboard switching and the picker work normally; recommended for AutoFill tests.
///
/// Commands (Darwin notifications): `harness-mic`, `harness-mic-hop` (a tap on the mic key in open-app
/// mode, plus the URL its Link would open), `harness-type` (the scripted typing cases below),
/// `harness-numbers` (tap the 123 key).
///
/// The field edit queue (`-LegatoFieldEdits YES` forces it on): `harness-fieldedits` runs the scripted edits
/// of scenario fe over a lagging document (`HarnessDocument.lag`: a Live run streamed by a scripted host, the
/// word row, undo and redo, a version swap, typing while a revision waits for a read that lags past the settle
/// timeout, deleting into the word a waiting revision rewrites, a write the field never shows);
/// `harness-fe-lag` measures how long a key press, a word-row tap and ↶ take until the action returns
/// (`fe.lag`), with the queue on or off, then how long keys take over the lagging document while the host sends
/// and clears the field after each Return before it reports it (`fe.lagsend`: a read none of our states is, so
/// the queue's prediction is contradicted until a read decides; `fe.step name=send-cleared` after the first
/// round's keys). Both register their own Darwin observers.
@MainActor
final class HarnessDocument: TextDocument {
    let textView = UITextView()
    let documentID: String? = "harness-document"
    /// Tells the keyboard the cursor or the text changed, as the extension's `textDidChange` and `selectionDidChange` do.
    private let observer = HarnessSelectionObserver()
    var onChange: (() -> Void)?

    private static func argument(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }

    init() {
        textView.accessibilityIdentifier = "harness.document"
        textView.font = .preferredFont(forTextStyle: .title3)
        // The system keyboard never shows over the harness: the Legato keys are the only input.
        textView.inputView = UIView()
        textView.delegate = observer
        observer.onChange = { [weak self] in
            guard let self, self.lag == nil else { return }  // a lagging proxy tells when its report arrives
            self.onChange?()
        }
    }

    var text: String { textView.text ?? "" }

    /// A lagging proxy, like the extension's `textDocumentProxy`: while set, every call changes the field at once,
    /// but the context reads (and `onChange`, the `textDidChange` / `selectionDidChange` callbacks) follow `lag`
    /// after it, in order, one state per call: after a caret move, after each deleted Character, after an insert.
    /// A write's reads thus show its intermediate states, and late ones arrive after the settle timeout.
    var lag: Duration? {
        didSet {
            if lag != nil, oldValue == nil { reported = (liveBefore, liveAfter) }
        }
    }
    private var reported: (before: String, after: String)?
    /// The states not reported yet, oldest first, each with when it is due (never before the one ahead of it).
    private var unreported: [(due: ContinuousClock.Instant, before: String, after: String)] = []
    /// The next write's calls never reach the field (a write the host lost).
    var dropsNextWrite = false

    /// Whether every state the field went through has been reported.
    var caughtUp: Bool { unreported.isEmpty }

    /// The field's current state, reported `lag` after now (after every earlier report, in order).
    private func reportLater() {
        guard let lag else { return }
        let due = max(unreported.last?.due ?? .now, .now + lag)
        unreported.append((due, liveBefore, liveAfter))
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            self?.reportDue()
        }
    }

    /// Reports every state that is due, oldest first, one callback each (tasks may wake in any order).
    private func reportDue() {
        while let next = unreported.first, next.due <= .now {
            unreported.removeFirst()
            if lag != nil { reported = (next.before, next.after) }
            onChange?()
        }
    }

    /// The field starts over (empty, reported at once).
    func reset() {
        textView.text = ""
        if lag != nil { reported = ("", "") }
    }

    /// The host empties the field (a chat app sending the message) and reports that at once, ahead of the states
    /// of our calls it has not reported yet (they went with the text): a read that is none of our states.
    func hostClears() {
        textView.text = ""
        if lag != nil {
            unreported = []
            reported = ("", "")
        }
        onChange?()
    }

    /// The user puts the caret at `location`; the host reports it after everything before it.
    func userMoveCaret(to location: Int) {
        textView.selectedRange = NSRange(location: location, length: 0)
        if lag != nil { reportLater() } else { onChange?() }
    }

    var contextBefore: String { lag != nil ? reported?.before ?? liveBefore : liveBefore }
    var contextAfter: String { lag != nil ? reported?.after ?? liveAfter : liveAfter }

    /// `-LegatoHarnessContextLimit <n>`: the host reports the text before the caret only from the last multiple
    /// of `n` UTF-16 units on, like an iOS host (WhatsApp) whose before-context loses its head as the text grows.
    private static let contextLimit = Int(argument("LegatoHarnessContextLimit") ?? "") ?? 0

    private var liveBefore: String {
        let ns = text as NSString
        let caret = min(textView.selectedRange.location, ns.length)
        guard Self.contextLimit > 0, caret > 0 else { return ns.substring(to: caret) }
        let start = (caret - 1) / Self.contextLimit * Self.contextLimit
        return ns.substring(with: NSRange(location: start, length: caret - start))
    }

    private var liveAfter: String {
        let ns = text as NSString
        let end = min(textView.selectedRange.location + textView.selectedRange.length, ns.length)
        return ns.substring(from: end)
    }

    /// The caret in UTF-16 units.
    var caret: Int { textView.selectedRange.location }

    var selectedText: String? {
        let range = textView.selectedRange
        guard range.length > 0 else { return nil }
        return (text as NSString).substring(with: range)
    }

    var isSecureTextEntry: Bool { false }
    var textContentType: UITextContentType? { nil }

    var returnKeyType: UIReturnKeyType {
        switch Self.argument("LegatoHarnessReturn") {
        case "send": .send
        case "go": .go
        case "search": .search
        case "next": .next
        case "done": .done
        case "join": .join
        default: .default
        }
    }

    var keyboardType: UIKeyboardType {
        switch Self.argument("LegatoHarnessKeyboardType") {
        case "email": .emailAddress
        case "url": .URL
        case "number": .numberPad
        case "phone": .phonePad
        case "decimal": .decimalPad
        case "numbers": .numbersAndPunctuation
        default: .default
        }
    }

    var autocapitalizationType: UITextAutocapitalizationType { Self.argument("LegatoHarnessAutocap") == "NO" ? .none : .sentences }
    var enablesReturnKeyAutomatically: Bool { false }
    var hasText: Bool { textView.hasText }

    var keyboardAppearance: UIKeyboardAppearance {
        switch Self.argument("LegatoHarnessAppearance") {
        case "dark": .dark
        case "light": .light
        default: .default
        }
    }

    func insert(_ text: String) {
        textView.insertText(text)
        reportLater()
    }
    func deleteBackward() {
        textView.deleteBackward()
        reportLater()
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        // The proxy counts UTF-16 units, as UITextView's NSRange does.
        let current = textView.selectedRange
        let length = (text as NSString).length
        let location = min(max(current.location + current.length + offset, 0), length)
        textView.selectedRange = NSRange(location: location, length: 0)
        reportLater()
    }

    /// The queue's calls, as `TextDocument.execute` runs them, unless the write is to be lost.
    func execute(_ calls: [ProxyCall]) {
        if dropsNextWrite {
            dropsNextWrite = false
            E2E.log("harness fe.dropped calls=\(calls.count)")
            return
        }
        for call in calls {
            switch call {
            case .moveCaret(let units): adjustTextPosition(byCharacterOffset: units)
            case .deleteBackward(let count): for _ in 0..<count { deleteBackward() }
            case .insert(let text): insert(text)
            }
        }
    }
}

@MainActor
private final class HarnessSelectionObserver: NSObject, UITextViewDelegate {
    var onChange: (() -> Void)?
    func textViewDidChangeSelection(_ textView: UITextView) { onChange?() }
    func textViewDidChange(_ textView: UITextView) { onChange?() }
}

@MainActor
final class KeyboardHarnessModel {
    static let shared = KeyboardHarnessModel()

    let document = HarnessDocument()
    let controller: KeyboardController
    private let link: LinkClient

    /// Scripted typing: the key sequences `harness-type` feeds through `TypingModel.press`, the same
    /// commit path the touches use. Tokens: `shift`, `space`, `delete`, `return`, a key id
    /// (`mode:numbers`), or any other word as its letters. The script holds the expected texts.
    static let typingCases: [(name: String, keys: String)] = [
        ("autocap", "hi"),
        ("double-space", "hi space space there"),
        ("single-space", "hi space there"),
        ("shift", "hi space shift bye"),
        ("caps-lock", "hi space shift shift ab shift c"),
        ("delete", "hello space world delete delete"),
        ("delete-recapitalizes", "ab delete delete c"),
        ("numbers", "ab mode:numbers 1 2 mode:letters c"),
        ("double-space-after-punctuation", "ok mode:numbers , space space mode:letters x"),
    ]

    private init() {
        let document = self.document
        let link = LinkClient()
        self.link = link
        controller = KeyboardController(
            document: document, link: link, hasFullAccess: { true },
            preferences: {
                var preferences = KeyboardPreferences.load()
                if ["YES", "TRUE", "1"].contains(UserDefaults.standard.string(forKey: "LegatoHarnessStrip")?.uppercased() ?? "") {
                    preferences.strip = true
                }
                return preferences
            })
        controller.trace = { message in E2E.log("harness \(message) doc=\(E2E.quote(document.text))") }
        controller.beforeStartWatch = { await E2E.waitForStartWatch() }
        document.onChange = { [weak controller] in controller?.documentDidChange() }
        let namespace = "\(RuntimeIdentity.current.notificationNamespace).e2e."
        fieldEditObservers = ["harness-fieldedits", "harness-fe-lag", "harness-agent-edit", "harness-host-send"].map { command in
            DarwinObserver(name: namespace + command) {
                Task { @MainActor in
                    E2E.log("command \(command)")
                    switch command {
                    case "harness-fieldedits": await KeyboardHarnessModel.shared.runFieldEdits()
                    case "harness-agent-edit": await KeyboardHarnessModel.shared.typeIntoRunWhileTheAgentThinks()
                    case "harness-host-send": await KeyboardHarnessModel.shared.hostSendsMidRun()
                    default: await KeyboardHarnessModel.shared.measureLag()
                    }
                }
            }
        }
    }

    private var fieldEditObservers: [DarwinObserver] = []

    func appeared() {
        controller.showsGlobe = ["YES", "TRUE", "1"].contains(UserDefaults.standard.string(forKey: "LegatoHarnessGlobe")?.uppercased() ?? "")
        if let list = UserDefaults.standard.string(forKey: "LegatoHarnessSuggestions") {
            controller.pinSuggestions(list.split(separator: ",").map(String.init))
        }
        controller.appeared()
        let typing = controller.typing!
        E2E.log("harness ready returnLabel=\(E2E.quote(typing.presentation.returnLabel)) spaceLabel=\(E2E.quote(typing.presentation.spaceLabel)) page=\(typing.page) keys=\(typing.layout.rows.map { String($0.keys.count) }.joined(separator: ","))")
    }

    func run(_ command: String) {
        switch command {
        case "harness-mic": controller.micTapped()
        case "harness-host-missing": link.hidesHost = true
        case "harness-status":
            E2E.log("harness status=\(E2E.quote(controller.dictationStatus ?? "")) capturing=\(controller.isCapturing ? 1 : 0) command=\(controller.micMode.request?.rawValue ?? "none") doc=\(E2E.quote(document.text))")
        case "harness-mic-hop":
            // What the open-app mic key does: the Link opens the app with its URL as the tap lands.
            let url = KeyboardURL.make(command: controller.openAppCommand, requestID: controller.openAppRequestID)
            controller.micTapped()
            Task { await AppController.shared.handle(url) }
        case "harness-mic-hop-retry":
            Task {
                for _ in 0..<2 {
                    let url = KeyboardURL.make(command: controller.openAppCommand, requestID: controller.openAppRequestID)
                    controller.micTapped()
                    await AppController.shared.handle(url)
                    // Return to the host keyboard immediately after the failed activation.
                    controller.disappeared()
                    controller.appeared()
                }
                E2E.log("harness hop-retry.done")
            }
        case "harness-numbers": controller.typing.press(keyID: "mode:numbers")
        case "harness-type": runTypingCases()
        default: E2E.log("harness.unknown \(command)")
        }
    }

    private func runTypingCases() {
        let typing = controller.typing!
        for (name, keys) in Self.typingCases {
            document.textView.text = ""
            typing.reset()
            for token in keys.split(separator: " ") {
                let token = String(token)
                if ["shift", "space", "delete", "return"].contains(token) || token.contains(":") {
                    typing.press(keyID: token)
                } else {
                    for ch in token { typing.press(keyID: "char:\(ch)") }
                }
            }
            E2E.log("harness typing case=\(name) text=\(E2E.quote(document.text)) shift=\(typing.shift.mode)")
        }
    }

    // MARK: Field edit queue (scenario fe)

    private let linkStore = UserDefaultsLinkStore().map(LinkStore.init)
    private var hostSeq = 10_000

    /// What the app would publish for a scripted Live run (fresh beat), followed by its Darwin note.
    private func publish(
        run: String, phase: HostPhase = .listening, committed: String, finalText: String? = nil,
        revision: HostRevision? = nil
    ) {
        hostSeq += 1
        let state = HostState(
            runID: run, phase: phase, target: .keyboard, committed: committed, volatile: "", seq: hostSeq,
            beatAt: Date(), leaseUntil: nil, acceptsRemoteStart: false, delivery: .live, finalText: finalText,
            revision: revision)
        linkStore?.write(state, forKey: LinkChannel.Key.host)
        DarwinObserver.post(LinkChannel.Note.host)
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                E2E.log("fe.timeout what=\(what) doc=\(E2E.quote(document.text))")
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func step(_ name: String) {
        E2E.log("fe.step name=\(name) doc=\(E2E.quote(document.text)) caret=\(document.caret) end=\((document.text as NSString).length)")
    }

    private func press(_ keys: String) {
        let typing = controller.typing!
        for token in keys.split(separator: " ") {
            let token = String(token)
            if ["shift", "space", "delete", "return"].contains(token) { typing.press(keyID: token) }
            else { for ch in token { typing.press(keyID: "char:\(ch)") } }
        }
    }

    /// The pinned words again: a new field's first change clears the row, pinned words included.
    private func repin() {
        if let list = UserDefaults.standard.string(forKey: "LegatoHarnessSuggestions") {
            controller.pinSuggestions(list.split(separator: ",").map(String.init))
        }
    }

    private func clearField() {
        document.reset()
        controller.typing.reset()
        controller.documentDidChange()
    }

    /// Every state the field went through is reported and the queue has nothing left to verify or write.
    private func settled(_ what: String) async {
        await waitUntil(what, timeout: 5) { document.caughtUp && !controller.fieldEditsBusy }
    }

    /// Scenario fe: every source of the keyboard through the queue, step by step, over a lagging document (its
    /// reads trail the calls, show every intermediate state, and some arrive after the 250 ms settle timeout);
    /// the script checks the logs.
    func runFieldEdits() async {
        E2E.log("fe.begin on=\(KeyboardPreferences.forcedFieldEdits ? 1 : 0)")
        clearField()
        document.lag = .milliseconds(60)

        // 1. A Live run streams (ASR lane) and its revision lands as a patch (cleanup lane) while the reveal rushes.
        //    The reads of the last chunk and of the revision lag 400 ms: past the timeout, so each final read is
        //    stale once and the write is confirmed when the host catches up, never typed twice.
        let run1 = "fe-run-1"
        publish(run: run1, committed: "teh")
        await waitUntil("stream-1", timeout: 5) { document.text == "teh" }
        publish(run: run1, committed: "teh cat sat")
        await waitUntil("stream-2", timeout: 5) { document.text == "teh cat sat" }
        await settled("stream-2-settled")
        document.lag = .milliseconds(400)
        let revision1 = HostRevision(n: 1, start: 0, raw: "teh cat sat", text: "the cat sat")
        publish(run: run1, committed: "teh cat sat on", revision: revision1)
        await waitUntil("revision", timeout: 5) { document.text == "the cat sat on" }
        await settled("revision-settled")
        document.lag = .milliseconds(60)
        publish(run: run1, phase: .idle, committed: "teh cat sat on", finalText: "the cat sat on", revision: revision1)
        await waitUntil("versions", timeout: 5) { controller.shownVersionIndex != nil }
        await settled("stream-settled")
        step("stream")

        // 2. The word row: the pinned word completes the word at the caret.
        repin()
        controller.suggestionTapped(rank: 0)
        step("row")

        // 3. Undo and redo: the completion, then the version swap (cleaned -> raw), and back; each runs at once,
        //    on the field as the writes before it left it, while their reads still trail.
        controller.undo()
        step("undo-row")
        controller.undo()
        step("undo-version")
        controller.redo()
        step("redo-version")
        controller.redo()
        step("redo-row")
        await settled("history-settled")

        // 4. Typing while a revision waits: revision 1's read lags 400 ms, so revision 2 waits in the queue; the
        //    keys run at once and the waiting revision is mapped past them and lands after them.
        let run2 = "fe-run-2"
        publish(run: run2, committed: "a dgo ran")
        await waitUntil("run2-stream", timeout: 5) { document.text.hasSuffix("a dgo ran") }
        await settled("run2-stream-settled")
        document.lag = .milliseconds(400)
        publish(run: run2, committed: "a dgo ran", revision: HostRevision(n: 1, start: 0, raw: "a dgo ran", text: "a dog ran"))
        await waitUntil("run2-revision1") { document.text.hasSuffix("a dog ran") }
        publish(run: run2, committed: "a dgo ran", revision: HostRevision(n: 2, start: 0, raw: "a dgo ran", text: "A dog ran"))
        await waitUntil("run2-revision2-waits") { controller.fieldEditsHostWaiting }
        E2E.log("fe.pending waiting=\(controller.fieldEditsHostWaiting ? 1 : 0)")
        press("space i s")
        step("typed-while-pending")
        await waitUntil("run2-revision2", timeout: 5) { document.text.hasSuffix("A dog ran is") }
        await settled("run2-settled")
        document.lag = .milliseconds(60)
        publish(run: run2, phase: .idle, committed: "a dgo ran", finalText: "A dog ran",
                revision: HostRevision(n: 2, start: 0, raw: "a dgo ran", text: "A dog ran"))
        try? await Task.sleep(for: .milliseconds(300))
        await settled("run2-final-settled")
        step("pending")

        // 5. Deleting into the word a waiting revision rewrites ("dgo" -> "dog"): the revision is handed back as
        //    the user's change (overlap, byUser) and the user's text stays.
        let run3 = "fe-run-3"
        publish(run: run3, committed: "the dgo")
        await waitUntil("run3-stream", timeout: 5) { document.text.hasSuffix(" the dgo") }
        await settled("run3-stream-settled")
        document.lag = .milliseconds(400)
        publish(run: run3, committed: "the dgo", revision: HostRevision(n: 1, start: 0, raw: "the dgo", text: "The dgo"))
        await waitUntil("run3-revision1") { document.text.hasSuffix(" The dgo") }
        publish(run: run3, committed: "the dgo", revision: HostRevision(n: 2, start: 0, raw: "the dgo", text: "The dog"))
        await waitUntil("run3-revision2-waits") { controller.fieldEditsHostWaiting }
        step("before-same-word")
        press("delete delete i")
        step("typed-into-pending")
        await settled("run3-settled")
        document.lag = .milliseconds(60)
        publish(run: run3, phase: .idle, committed: "the dgo", finalText: "The dog",
                revision: HostRevision(n: 2, start: 0, raw: "the dgo", text: "The dog"))
        try? await Task.sleep(for: .milliseconds(300))
        await settled("run3-final-settled")
        step("same-word")

        // 6. A write the field never shows (the host lost it): its reads stay stale through the extended wait, it
        //    fails once, and the chunk (with the tick waiting behind it) is typed again, exactly once.
        let run4 = "fe-run-4"
        publish(run: run4, committed: "one")
        await waitUntil("run4-stream", timeout: 5) { document.text.hasSuffix(" one") }
        await settled("run4-stream-settled")
        document.dropsNextWrite = true
        publish(run: run4, committed: "one two three")
        await waitUntil("run4-retyped", timeout: 5) { document.text.hasSuffix(" one two three") }
        await settled("run4-settled")
        publish(run: run4, phase: .idle, committed: "one two three")
        try? await Task.sleep(for: .milliseconds(300))
        await settled("run4-final-settled")
        step("dropped")
        document.lag = nil
        E2E.log("fe.done")
    }

    // MARK: The app's cleanup agent (scenario fa)

    /// The script's words as the stream leaves them (the fake engine's text).
    private var scriptText: String { UserDefaults.standard.string(forKey: "LegatoFakeEngine") ?? "" }

    /// Scenario fa: once the stream committed the whole script and the agent's first turn is in flight, the user taps
    /// into the first word (after its second letter), types "x" and taps the end again: the agent's pending edit of
    /// that sentence comes back as the user's (conflict, with the note), and the agent goes on with the next one.
    func typeIntoRunWhileTheAgentThinks() async {
        let script = scriptText
        await waitUntil("agent-ask", timeout: 15) {
            // All of it committed (the engine's final words end in a space): nothing of the run is still to be typed.
            E2E.agentAsksInFlight.withLock { $0 } > 0 && document.text == script + " "
        }
        document.userMoveCaret(to: 2)
        controller.typing.press(keyID: "char:x")
        document.userMoveCaret(to: (document.text as NSString).length)
        step("agent-user-edit")
    }

    /// Scenario fa: once the stream typed the first sentence, the host sends and empties the field (a chat app's
    /// Send); the rest of the run streams into the empty field.
    func hostSendsMidRun() async {
        await waitUntil("first-sentence", timeout: 15) { document.text.contains(".") }
        document.hostClears()
        step("host-sent")
    }

    /// Scenario fe's lag probe: how long a key press, a word-row tap or ↶ takes, from the call until it returns
    /// (the proxy calls and everything the queue does after them: settling, dispatching, pruning).
    func measureLag() async {
        clearField()
        var keys: [Double] = [], taps: [Double] = [], undos: [Double] = []
        let typing = controller.typing!
        for round in 0..<20 {
            for ch in "ab" { keys.append(measure { _ = typing.press(keyID: "char:\(ch)") }) }
            repin()
            taps.append(measure { controller.suggestionTapped(rank: 0) })
            if round % 2 == 0 { undos.append(measure { controller.undo() }) }
            try? await Task.sleep(for: .milliseconds(30))
        }
        for ch in "lagprobe" { keys.append(measure { _ = typing.press(keyID: "char:\(ch)") }) }
        let on = KeyboardPreferences.forcedFieldEdits ? 1 : 0
        E2E.log("fe.lag on=\(on) keys=\(keys.count) taps=\(taps.count) undos=\(undos.count) \(Self.stats("key", keys)) \(Self.stats("tap", taps)) \(Self.stats("undo", undos)) doc=\(E2E.quote(document.text))")

        // The lagging document (60 ms), and a host that sends and clears the field after each Return before it
        // reports it: the keys after it are typed in the call they arrive, none waits and none is lost.
        clearField()
        document.lag = .milliseconds(60)
        var sent: [Double] = []
        for round in 0..<10 {
            for ch in "hi" { sent.append(measure { _ = typing.press(keyID: "char:\(ch)") }) }
            await settled("lagsend-typed")
            sent.append(measure { _ = typing.press(keyID: "return") })
            document.hostClears()
            for ch in "ok" { sent.append(measure { _ = typing.press(keyID: "char:\(ch)") }) }
            if round == 0 { step("send-cleared") }
            try? await Task.sleep(for: .milliseconds(30))
        }
        await settled("lagsend-settled")
        step("sent")
        document.lag = nil
        E2E.log("fe.lagsend on=\(on) keys=\(sent.count) \(Self.stats("key", sent)) doc=\(E2E.quote(document.text))")
    }

    /// How long `action` takes, in milliseconds.
    private func measure(_ action: () -> Void) -> Double {
        let start = ContinuousClock.now
        action()
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    /// `<name>Ms=<median> <name>P95Ms=<p95> <name>MaxMs=<max>`.
    private static func stats(_ name: String, _ values: [Double]) -> String {
        guard !values.isEmpty else { return "\(name)Ms=- \(name)P95Ms=- \(name)MaxMs=-" }
        let sorted = values.sorted()
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return String(format: "\(name)Ms=%.3f \(name)P95Ms=%.3f \(name)MaxMs=%.3f", sorted[sorted.count / 2], p95, sorted.last!)
    }
}

struct KeyboardHarness: View {
    private let model = KeyboardHarnessModel.shared

    private static func flag(_ key: String) -> Bool {
        ["YES", "TRUE", "1"].contains(UserDefaults.standard.string(forKey: key)?.uppercased() ?? "")
    }

    private var scheme: ColorScheme? {
        switch UserDefaults.standard.string(forKey: "LegatoHarnessAppearance") {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// The keyboard's backdrop (the real one is the system's keyboard glass), and the system area below
    /// the keys on a Face ID iPhone (globe and dictation key), which the extension doesn't own.
    private static let backdrop = Color(uiColor: UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(red: 26 / 255, green: 26 / 255, blue: 28 / 255, alpha: 1) : UIColor(red: 226 / 255, green: 228 / 255, blue: 232 / 255, alpha: 1)
    })
    private static let systemArea: CGFloat = 68

    var body: some View {
        Group {
            if Self.flag("LegatoHarnessSystemField") {
                SystemFieldHost().ignoresSafeArea()
            } else if Self.flag("LegatoHarnessLandscape") {
                GeometryReader { geometry in
                    // 874 pt wide, turned a quarter turn: a landscape phone's keyboard on the portrait screen.
                    let length = geometry.size.height
                    VStack(spacing: 0) {
                        HarnessTextView(textView: model.document.textView).padding(8)
                        keyboard.frame(height: KeyGeometry.height(landscape: true)).background(Self.backdrop)
                    }
                    .frame(width: length, height: geometry.size.width)
                    .background(.background)
                    .rotationEffect(.degrees(-90))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    HarnessTextView(textView: model.document.textView).padding(8)
                    VStack(spacing: 0) {
                        keyboard.frame(height: portraitHeight)
                        Color.clear.frame(height: Self.systemArea)
                    }
                    .background(Self.backdrop)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .preferredColorScheme(scheme)
        .onAppear { model.appeared() }
        .onDisappear { model.controller.disappeared() }
    }

    /// The strip asks for its own height (`StripHeight.requested`), the full keyboard for the portrait one.
    private var portraitHeight: CGFloat {
        model.controller.mode == .strip
            ? CGFloat(StripHeight.requested(row: model.controller.stripHeight)) : KeyGeometry.height(landscape: false)
    }

    private var keyboard: some View {
        KeyboardRootView(controller: model.controller)
    }
}

/// A text field in a plain view controller, first responder from the start, whose `textInputMode` is the
/// Legato extension's (found among the active input modes by its identifier).
private struct SystemFieldHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SystemFieldController { SystemFieldController() }
    func updateUIViewController(_ controller: SystemFieldController, context: Context) {}
}

private final class LegatoModeTextField: UITextField {
    var pinsLegato = true
    override var textInputMode: UITextInputMode? {
        guard pinsLegato else { return super.textInputMode }
        return UITextInputMode.activeInputModes.first { ($0.value(forKey: "identifier") as? String)?.contains("de.gruenwald.legato") == true }
            ?? super.textInputMode
    }
}

private final class SystemFieldController: UIViewController {
    private let field = LegatoModeTextField()
    private var didFocus = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let defaults = UserDefaults.standard
        let contentTypes: [String: UITextContentType] = [
            "username": .username, "password": .password, "newPassword": .newPassword,
            "oneTimeCode": .oneTimeCode, "emailAddress": .emailAddress, "URL": .URL,
        ]
        field.accessibilityIdentifier = "systemfield.document"
        field.placeholder = "Initial field"
        field.textContentType = defaults.string(forKey: "LegatoHarnessContentType").flatMap { contentTypes[$0] }
        field.isSecureTextEntry = defaults.bool(forKey: "LegatoHarnessSecure")

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(field)
        let siblingFields: [(String, UITextContentType, Bool)] = [
            ("username", UITextContentType.username, false),
            ("password", .password, true),
            ("newPassword", .newPassword, false),
            ("oneTimeCode", .oneTimeCode, false),
            ("emailAddress", .emailAddress, false),
            ("prose", UITextContentType(rawValue: ""), false),
        ]
        for (name, type, secure) in defaults.bool(forKey: "LegatoHarnessSingleField") ? [] : siblingFields {
            let extra = UITextField()
            extra.placeholder = name
            extra.accessibilityIdentifier = "systemfield.\(name)"
            extra.textContentType = type
            extra.isSecureTextEntry = secure
            if name == "emailAddress" { extra.keyboardType = .emailAddress }
            stack.addArrangedSubview(extra)
        }
        for case let input as UITextField in stack.arrangedSubviews {
            input.borderStyle = .roundedRect
            input.autocorrectionType = .no
            input.autocapitalizationType = .none
            if let appearance = defaults.string(forKey: "LegatoHarnessAppearance") {
                input.keyboardAppearance = appearance == "dark" ? .dark : .light
            }
        }
        let releasePin = UIButton(type: .system)
        releasePin.setTitle("Release keyboard pin", for: .normal)
        releasePin.accessibilityIdentifier = "systemfield.releasePin"
        releasePin.addAction(UIAction { [weak self] _ in
            self?.field.pinsLegato = false
            E2E.log("systemfield pin=released")
        }, for: .touchUpInside)
        stack.addArrangedSubview(releasePin)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didFocus else { return }
        didFocus = true
        let modes = UITextInputMode.activeInputModes.map { ($0.value(forKey: "identifier") as? String) ?? "?" }
        E2E.log("systemfield modes=\(E2E.quote(modes.joined(separator: ",")))")
        field.becomeFirstResponder()
        if UserDefaults.standard.bool(forKey: "LegatoHarnessUnpinKeyboard") { field.pinsLegato = false }
    }
}

private struct HarnessTextView: UIViewRepresentable {
    let textView: UITextView
    func makeUIView(context: Context) -> UITextView { textView }
    func updateUIView(_ view: UITextView, context: Context) {}
}
#endif
