import SwiftUI

/// The same opaque head and connected stem used by keyboard key popups, contained in the input view.
struct KeyboardModePicker: View {
    let modes: [(String, String)]
    let selected: String
    let keyWidth: CGFloat
    let maximumHeight: CGFloat
    let onSelect: (String) -> Void

    private var cardHeight: CGFloat { min(CGFloat(modes.count) * 40 + 8, maximumHeight) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(modes, id: \.0) { mode, icon in
                    Button { onSelect(mode) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).frame(width: 24)
                            Text(mode.capitalized)
                            Spacer(minLength: 8)
                            if selected == mode {
                                Image(systemName: "checkmark").foregroundStyle(Color(uiColor: KeyColors.accent))
                            }
                        }
                        .font(.system(size: 17)).foregroundStyle(Color(uiColor: KeyColors.ink))
                        .padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(KeyboardModeRowStyle())
                    .accessibilityLabel(mode.capitalized)
                    .accessibilityAddTraits(selected == mode ? .isSelected : [])
                }
            }.padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .frame(height: cardHeight).padding(.bottom, 8)
        .background(KeyboardModePopupShape(keyWidth: keyWidth).fill(Color(uiColor: KeyColors.popup)))
        .shadow(color: Color(uiColor: KeyColors.shadow), radius: 4, x: 0, y: -1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Writing modes")
        .accessibilityIdentifier("keyboard.mode-picker")
    }
}

struct KeyboardModeKeyStyle: ButtonStyle {
    let expanded: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(
            RoundedRectangle(cornerRadius: KeyGeometry.keyRadius)
                .fill(Color(uiColor: expanded ? KeyColors.popup : configuration.isPressed ? KeyColors.pressed : KeyColors.key)))
    }
}

private struct KeyboardModeRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color(uiColor: KeyColors.pressed) : Color.clear)
    }
}

private struct KeyboardModePopupShape: Shape {
    let keyWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 12
        let bottom = rect.maxY - 8
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: radius), control: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
        path.addLine(to: CGPoint(x: keyWidth + 6, y: bottom))
        path.addQuadCurve(to: CGPoint(x: keyWidth, y: rect.maxY), control: CGPoint(x: keyWidth, y: bottom))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        return path
    }
}
