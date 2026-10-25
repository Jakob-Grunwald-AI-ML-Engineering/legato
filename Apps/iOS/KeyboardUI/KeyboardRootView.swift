import SwiftUI
import UIKit

/// A minimal key grid: lowercase QWERTY, delete, and a bottom row of globe (when iOS asks for one),
/// mic, space and return. The typing engine and the full layout replace this later.
struct KeyboardRootView: View {
    let controller: KeyboardController

    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    var body: some View {
        VStack(spacing: 8) {
            Text(controller.hint ?? " ")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 18)
                .accessibilityIdentifier("keyboard.hint")

            letters(Self.rows[0])
            letters(Self.rows[1]).padding(.horizontal, 16)
            HStack(spacing: 6) {
                letters(Self.rows[2])
                Button { controller.deleteBackward() } label: {
                    Image(systemName: "delete.left").frame(maxWidth: .infinity, minHeight: KeyStyle.height)
                }
                .buttonStyle(KeyStyle(fill: Color(uiColor: .systemGray3)))
                .frame(width: 52)
                .accessibilityIdentifier("key.delete")
            }
            .padding(.horizontal, 8)

            HStack(spacing: 6) {
                if controller.showsGlobe {
                    GlobeKey(target: controller.inputModeTarget).frame(width: 44, height: KeyStyle.height)
                }
                MicKey(controller: controller).frame(width: 64)
                Button { controller.type(" ") } label: {
                    Text("space").frame(maxWidth: .infinity, minHeight: KeyStyle.height)
                }
                .buttonStyle(KeyStyle(fill: Color(uiColor: .systemBackground)))
                .accessibilityIdentifier("key.space")
                Button { controller.type("\n") } label: {
                    Text(Self.returnLabel(controller.returnKeyType)).frame(maxWidth: .infinity, minHeight: KeyStyle.height)
                }
                .buttonStyle(KeyStyle(fill: Color(uiColor: .systemGray3)))
                .frame(width: 84)
                .accessibilityIdentifier("key.return")
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 6)
    }

    private func letters(_ row: String) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(row), id: \.self) { letter in
                Button { controller.type(String(letter)) } label: {
                    Text(String(letter)).font(.system(size: 22)).frame(maxWidth: .infinity, minHeight: KeyStyle.height)
                }
                .buttonStyle(KeyStyle(fill: Color(uiColor: .systemBackground)))
                .accessibilityIdentifier("key.\(letter)")
            }
        }
    }

    static func returnLabel(_ type: UIReturnKeyType) -> String {
        switch type {
        case .go: "go"
        case .google, .search, .yahoo: "search"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .send: "send"
        case .done: "done"
        case .emergencyCall: "emergency"
        case .continue: "continue"
        default: "return"
        }
    }
}

/// A key cap: a rounded rectangle that darkens while pressed.
struct KeyStyle: ButtonStyle {
    static let height: CGFloat = 42
    static let radius: CGFloat = 6

    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(fill.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: Self.radius))
            .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            .contentShape(Rectangle())
    }
}

/// The globe key: a `UIButton` wired to `handleInputModeList`, which switches to the next keyboard on a
/// tap and shows the keyboard list on a long press. SwiftUI buttons can't do the long press.
struct GlobeKey: UIViewRepresentable {
    weak var target: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.backgroundColor = .systemGray3
        button.layer.cornerRadius = KeyStyle.radius
        button.accessibilityIdentifier = "key.globe"
        if let target {
            button.addTarget(target, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}
