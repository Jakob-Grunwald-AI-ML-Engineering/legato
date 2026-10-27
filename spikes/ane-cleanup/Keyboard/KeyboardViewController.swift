import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var timer: Timer?
    private let status = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        let toggle = UIButton(type: .system)
        toggle.setTitle("Start / Stop ANE spike", for: .normal)
        toggle.addTarget(self, action: #selector(sendToggle), for: .touchUpInside)
        let fixture = UIButton(type: .system)
        fixture.setTitle("Run selected fixture in background", for: .normal)
        fixture.addTarget(self, action: #selector(sendFixture), for: .touchUpInside)
        let globe = UIButton(type: .system)
        globe.setTitle("Next keyboard", for: .normal)
        globe.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)
        let arm = UIHostingController(rootView: Link("Open spike to arm microphone", destination: URL(string: "anecleanup39://arm")!))
        addChild(arm); arm.didMove(toParent: self)
        status.textAlignment = .center
        status.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [status, toggle, fixture, arm.view, globe])
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); timer?.invalidate(); timer = nil }
    @objc private func nextKeyboard() { advanceToNextInputMode() }
    @objc private func sendFixture() { send(command: "fixture") }
    @objc private func sendToggle() { send(command: "toggle") }
    private func send(command: String) {
        guard hasFullAccess else { status.text = "Enable Full Access for this spike keyboard."; return }
        let request = SpikeRequest(command: command)
        SpikeIDs.defaults.set(try? JSONEncoder().encode(request), forKey: "request")
        SpikeIDs.defaults.synchronize()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(SpikeIDs.requestNote as CFString), nil, nil, true)
        status.text = "Request \(request.id.uuidString.prefix(8)) sent"
    }
    private func refresh() {
        SpikeIDs.defaults.synchronize()
        status.text = SpikeIDs.defaults.string(forKey: "status") ?? "Open the spike and arm its microphone first."
        guard let data = SpikeIDs.defaults.data(forKey: "result"),
              let result = try? JSONDecoder().decode(SpikeResult.self, from: data),
              Date().timeIntervalSince(result.created) < 120,
              SpikeIDs.defaults.string(forKey: "insertedRun") != result.runID else { return }
        textDocumentProxy.insertText(result.text)
        SpikeIDs.defaults.set(result.runID, forKey: "insertedRun")
        SpikeIDs.defaults.set(Date().timeIntervalSince1970, forKey: "insertedAt")
        SpikeIDs.defaults.synchronize()
    }
}
