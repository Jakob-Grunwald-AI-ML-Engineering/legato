import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What the writer is doing with the spoken instruction on the strip.
public enum InstructionStripState: Equatable, Sendable {
    case idle, listening, applying, applied
    /// The writer could not apply the instruction.
    case failed
    /// A host notice (for example "No bound text field. Draft kept.") in place of the status.
    case notice(String)

    /// Maps `ComposerSession.instructionStatus`; anything that is not a known status is a notice.
    public init(status: String) {
        switch status {
        case "Ready": self = .idle
        case "Listening": self = .listening
        case "Applying", "Sending": self = .applying
        case "Done": self = .applied
        case "Failed": self = .failed
        default: self = .notice(status)
        }
    }
}

/// The composer's single line of voice: the live tail and the current instruction, at most three lines,
/// always scrolled to the latest words, with the sending/applied status. Fixed height, so the draft above
/// keeps its size while speech comes and goes.
public struct InstructionStrip: View {
    public static let lineCount = 3
    public static let fontSize: CGFloat = 15
    public static let lineSpacing: CGFloat = 2
    private static let verticalPadding: CGFloat = 8
    /// Three lines of text plus padding; the strip never grows or shrinks.
    public static var height: CGFloat { textHeight + verticalPadding * 2 }
    private static var textHeight: CGFloat {
        ceil(CGFloat(lineCount) * (StripFont.lineHeight(fontSize) + lineSpacing))
    }

    public let text: String
    public let state: InstructionStripState
    public var onDiscard: () -> Void

    public init(text: String, state: InstructionStripState, onDiscard: @escaping () -> Void = {}) {
        self.text = text; self.state = state; self.onDiscard = onDiscard
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Text(trimmed.isEmpty ? placeholder : trimmed)
                        .font(.system(size: Self.fontSize)).lineSpacing(Self.lineSpacing)
                        .foregroundStyle(trimmed.isEmpty || state == .applied ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("instruction-strip-text")
                    Color.clear.frame(height: 0).id("instruction-strip-end")
                }
                .scrollDisabled(true)
                .defaultScrollAnchor(.bottom)
                .frame(height: Self.textHeight)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: trimmed) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("instruction-strip-end", anchor: .bottom) }
                }
            }
            statusView.frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, Self.verticalPadding)
        .frame(height: Self.height)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 6)
        .animation(.smooth(duration: 0.2), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer.instruction-strip")
        .accessibilityLabel(trimmed.isEmpty ? placeholder : trimmed)
        .accessibilityValue(label)
    }

    private var placeholder: String {
        switch state {
        case .listening: "Listening…"
        default: "Tap the mic and say what to write or change"
        }
    }
    private var label: String {
        switch state {
        case .idle: "Ready"
        case .listening: "Listening"
        case .applying: "Applying"
        case .applied: "Applied"
        case .failed: "Not applied"
        case .notice(let value): value
        }
    }
    @ViewBuilder private var statusView: some View {
        switch state {
        case .idle:
            EmptyView()
        case .listening:
            Button(action: onDiscard) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).accessibilityLabel("Discard instruction")
            .accessibilityIdentifier("composer.instruction.discard")
        case .applying:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Applying").font(.caption2).foregroundStyle(.secondary)
            }
        case .applied:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                Text("Applied").font(.caption2)
            }.foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold))
                Text("Not applied").font(.caption2)
            }.foregroundStyle(.orange)
        case .notice(let value):
            Text(value).font(.caption2).foregroundStyle(.orange).lineLimit(3).multilineTextAlignment(.trailing)
                .frame(maxWidth: 110, alignment: .trailing)
        }
    }
}

private enum StripFont {
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        UIFont.systemFont(ofSize: size).lineHeight
        #else
        let font = NSFont.systemFont(ofSize: size)
        return font.ascender - font.descender + font.leading
        #endif
    }
}
