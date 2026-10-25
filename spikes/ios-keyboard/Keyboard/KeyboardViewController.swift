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
    var openURL: ((URL) -> Void)?

    private var timer: Timer?
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

    // MARK: start paths (b) and (c); path (a) is Button(intent:) in the view

    func startViaDarwin() {
        log("B: posted Darwin startSession")
        DarwinObserver.post(Spike.Note.startSession)
    }

    func startViaURL() {
        log("C: opening \(Spike.urlScheme)://start")
        openURL?(URL(string: "\(Spike.urlScheme)://start")!)
    }

    // MARK: dictation

    func toggleDictation() {
        let d = Spike.defaults
        let starting = !(dictState == "listening")
        if starting {
            currentDictation = Date().timeIntervalSince1970
            inserted = ""
            d.set(currentDictation, forKey: Spike.Key.commandSeq)
        } else {
            d.set(Date().timeIntervalSince1970, forKey: Spike.Key.commandSeq)
        }
        d.set(starting ? "start" : "stop", forKey: Spike.Key.command)
        DarwinObserver.post(Spike.Note.command)
        log("dictate \(starting ? "start" : "stop") sent")
    }

    /// Replace the previously inserted (volatile) text with the latest full text.
    private func applyText() {
        let d = Spike.defaults
        let seq = d.integer(forKey: Spike.Key.textSeq)
        guard seq != handledSeq else { return }
        handledSeq = seq
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
        model.openURL = { [unowned self] url in self.open(url) }
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

    /// Path (c): extensionContext.open first (documented but usually refused for keyboards),
    /// then the responder-chain UIApplication fallback.
    private func open(_ url: URL) {
        extensionContext?.open(url) { [weak self] ok in
            Task { @MainActor in
                self?.model.log("C: extensionContext.open ok=\(ok)")
                if !ok { self?.openViaResponderChain(url) }
            }
        }
    }

    private func openViaResponderChain(_ url: URL) {
        var r: UIResponder? = self
        while let x = r {
            if let app = x as? UIApplication {
                app.open(url, options: [:]) { [weak self] ok in
                    Task { @MainActor in self?.model.log("C: responder-chain open ok=\(ok)") }
                }
                return
            }
            r = x.next
        }
        model.log("C: no UIApplication in responder chain")
    }
}
