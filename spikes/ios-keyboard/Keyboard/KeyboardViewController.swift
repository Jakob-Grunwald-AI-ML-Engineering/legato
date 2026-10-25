import AppIntents
import SwiftUI
import UIKit

@MainActor @Observable
final class KeyboardModel {
    var alive = false
    var age: Double = -1
    var level: Float = 0
    var dictState = "idle"
    var lastEvent = "-"

    var proxy: (() -> UITextDocumentProxy)?

    private var timer: Timer?
    private var visibleTimer: Timer?
    private var observer: DarwinObserver?
    private var handledSeq = -1
    private var currentDictation: Double = 0
    private var inserted = ""

    func log(_ msg: String) {
        lastEvent = msg
        SpikeLog.write("kbd", msg)
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        observer = DarwinObserver(name: Spike.Note.text) { [weak self] in
            Task { @MainActor in self?.applyText() }
        }
        handledSeq = Spike.defaults.integer(forKey: Spike.Key.textSeq)
        currentDictation = Spike.defaults.double(forKey: Spike.Key.dictId)
    }

    func poll() {
        let d = Spike.defaults
        let t = d.double(forKey: Spike.Key.heartbeat)
        age = t > 0 ? Date().timeIntervalSince1970 - t : -1
        alive = d.bool(forKey: Spike.Key.active) && age >= 0 && age < 3
        level = d.float(forKey: Spike.Key.level)
        dictState = d.string(forKey: Spike.Key.dictState) ?? "idle"
        applyText()
    }

    // MARK: visibility (read by ToggleDictationIntent to choose keyboard vs Scratch)

    /// While visible, refresh `kbd.visibleAt` every second so a killed extension goes stale within ~2 s.
    func setVisible(_ visible: Bool) {
        let d = Spike.defaults
        d.set(visible, forKey: Spike.Key.kbdVisible)
        d.set(Date().timeIntervalSince1970, forKey: Spike.Key.kbdVisibleAt)
        visibleTimer?.invalidate(); visibleTimer = nil
        if visible {
            visibleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Spike.defaults.set(Date().timeIntervalSince1970, forKey: Spike.Key.kbdVisibleAt)
            }
        }
        SpikeLog.write("kbd", "visible=\(visible)")
    }

    // MARK: Darwin fallback path (only works while the app process is alive)

    func toggleViaDarwin() {
        log("FALLBACK: posted Darwin toggle")
        DarwinObserver.post(Spike.Note.toggle)
    }

    /// Replace the previously inserted (volatile) text with the latest full text.
    private func applyText() {
        let d = Spike.defaults
        let seq = d.integer(forKey: Spike.Key.textSeq)
        guard seq != handledSeq else { return }
        handledSeq = seq
        // A new dictation (started by the intent, not by us) resets what we have inserted so far.
        let id = d.double(forKey: Spike.Key.dictId)
        if id != currentDictation { currentDictation = id; inserted = "" }
        guard d.string(forKey: Spike.Key.dictTarget) == "keyboard" else { return }
        guard let proxy = proxy?() else { return }
        let text = d.string(forKey: Spike.Key.text) ?? ""
        if dictState.hasPrefix("error") { log("dictation \(dictState)"); return }
        guard dictState != "idle" || d.bool(forKey: Spike.Key.textFinal) else { return }
        for _ in 0..<inserted.count { proxy.deleteBackward() }
        proxy.insertText(text)
        inserted = d.bool(forKey: Spike.Key.textFinal) ? "" : text
        lastEvent = "inserted \(text.count) chars (seq \(seq))"
    }

    func insertTestString() {
        proxy?().insertText("Hallo Welt (Test) ")
        log("inserted fixed test string")
    }
}

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.proxy = { [unowned self] in self.textDocumentProxy }
        model.start()
        SpikeLog.write("kbd", "keyboard loaded; hasFullAccess=\(hasFullAccess)")

        let host = UIHostingController(rootView: KeyboardView(model: model, next: { [unowned self] in self.advanceToNextInputMode() }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 260),
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.setVisible(true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.setVisible(false)
    }
}
