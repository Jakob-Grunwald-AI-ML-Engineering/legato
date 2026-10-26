#if DEBUG
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
/// - `-LegatoHarnessSuggestions a,b,c`: fill the suggestion slots.
/// - `-LegatoHarnessGlobe YES`: show the globe key.
/// - `-LegatoHarnessLandscape YES`: lay the keyboard out 874 pt wide (landscape height), turned a quarter
///   turn so it fits the portrait screen (the screenshot is turned back).
///
/// - `-LegatoHarnessSystemField YES`: no harness at all: a plain text field that the system gives the real
///   Legato keyboard extension to (pins the field to the extension's input mode, see `SystemFieldHost`),
///   to look at the extension itself. Logs `systemfield modes=...` and the keyboard's own
///   `kbd.geometry` lines (see `KeyboardViewController`).
///
/// Commands (Darwin notifications): `harness-mic`, `harness-type` (the scripted typing cases below),
/// `harness-numbers` (tap the 123 key).
@MainActor
final class HarnessDocument: TextDocument {
    let textView = UITextView()
    let documentID = "harness-document"

    private static func argument(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }

    init() {
        textView.accessibilityIdentifier = "harness.document"
        textView.font = .preferredFont(forTextStyle: .title3)
        // The system keyboard never shows over the harness: the Legato keys are the only input.
        textView.inputView = UIView()
    }

    var text: String { textView.text ?? "" }

    var contextBefore: String {
        let ns = text as NSString
        return ns.substring(to: min(textView.selectedRange.location, ns.length))
    }

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

    func insert(_ text: String) { textView.insertText(text) }
    func deleteBackward() { textView.deleteBackward() }
}

@MainActor
final class KeyboardHarnessModel {
    static let shared = KeyboardHarnessModel()

    let document = HarnessDocument()
    let controller: KeyboardController

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
        controller = KeyboardController(document: document, link: LinkClient(), hasFullAccess: { true })
        controller.trace = { message in E2E.log("harness \(message) doc=\(E2E.quote(document.text))") }
    }

    func appeared() {
        controller.showsGlobe = ["YES", "TRUE", "1"].contains(UserDefaults.standard.string(forKey: "LegatoHarnessGlobe")?.uppercased() ?? "")
        if let list = UserDefaults.standard.string(forKey: "LegatoHarnessSuggestions") {
            controller.suggestions = list.split(separator: ",").map(String.init)
        }
        controller.appeared()
        let typing = controller.typing!
        E2E.log("harness ready returnLabel=\(E2E.quote(typing.presentation.returnLabel)) spaceLabel=\(E2E.quote(typing.presentation.spaceLabel)) page=\(typing.page) keys=\(typing.layout.rows.map { String($0.keys.count) }.joined(separator: ","))")
    }

    func run(_ command: String) {
        switch command {
        case "harness-mic": controller.micTapped()
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
                        keyboard.frame(height: KeyGeometry.height(landscape: false))
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
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { ($0.value(forKey: "identifier") as? String)?.contains("de.gruenwald.legato") == true }
            ?? super.textInputMode
    }
}

private final class SystemFieldController: UIViewController {
    private let field = LegatoModeTextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        field.accessibilityIdentifier = "systemfield.document"
        field.borderStyle = .roundedRect
        field.placeholder = "Legato keyboard"
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
        ])
        if let mode = UserDefaults.standard.string(forKey: "LegatoHarnessAppearance") {
            field.keyboardAppearance = mode == "dark" ? .dark : .light
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let modes = UITextInputMode.activeInputModes.map { ($0.value(forKey: "identifier") as? String) ?? "?" }
        E2E.log("systemfield modes=\(E2E.quote(modes.joined(separator: ",")))")
        field.becomeFirstResponder()
    }
}

private struct HarnessTextView: UIViewRepresentable {
    let textView: UITextView
    func makeUIView(context: Context) -> UITextView { textView }
    func updateUIView(_ view: UITextView, context: Context) {}
}
#endif
