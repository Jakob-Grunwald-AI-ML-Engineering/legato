import Foundation

/// iOS 26 prediction geometry. The system adds a 17 pt rounded area above portrait extensions;
/// that area is already included in Apple's 44 pt prediction view. Landscape adds no top area.
/// Measured with the actual extension and native keyboard; disabling host safe areas or changing
/// public input-view style leaves the system area unchanged. See the keyboard polishing validation.
public enum WordRowHeight {
    public static let visible = 44.0
    public static let portraitSystemTop = 17.0
    public static let portrait = visible - portraitSystemTop
    public static let strip = portrait

    public static func content(landscape: Bool) -> Double { landscape ? visible : portrait }
    /// Keeps portrait word ink at the native baseline within the complete visible row.
    public static func textOffset(landscape: Bool) -> Double { landscape ? 0 : -5.67 }
}

/// Predictions, one tool key row, then the unchanged native typing grid.
public enum KeyboardHeights {
    // The extension ends above iOS's globe/dictation area.
    private static let rowsBelow = 3 * 54.0 + 43 + 3

    public static func pillHeight(landscape: Bool) -> Double { landscape ? 27.33 : 43 }
    public static func pillGapToRow(landscape: Bool) -> Double { landscape ? 8 : 11 }
    public static func wordRowHeight(landscape: Bool) -> Double { WordRowHeight.content(landscape: landscape) }

    /// The native prediction-to-first-face gap: 8 pt portrait, 6 pt landscape.
    public static func toolRowTop(landscape: Bool) -> Double {
        wordRowHeight(landscape: landscape) + (landscape ? 6 : 8)
    }

    public static func firstRowTop(landscape: Bool) -> Double {
        toolRowTop(landscape: landscape) + (landscape ? 35.33 : 54)
    }

    public static func height(landscape: Bool) -> Double {
        firstRowTop(landscape: landscape) + (landscape ? 3 * 35.33 + 27.33 + 4 : rowsBelow)
    }
}

/// Horizontal inset still needed after iOS has inset the extension's content window.
public enum KeyboardSideMargins {
    public static func landscape(contentWidth: Double, screenWidth: Double?) -> Double {
        let systemInset = max(0, ((screenWidth ?? contentWidth) - contentWidth) / 2)
        return max(4, 79 - systemInset)
    }
}

/// Three composer sizes. Heights exclude iOS's rounded cap and bottom system tray.
public enum ComposerKeyboardSize: String, CaseIterable, Sendable {
    case low, medium, full

    public func height(screenHeight: Double, systemOverhead: Double, landscape: Bool = false) -> Double {
        let maximum = max(0, min(screenHeight - 60, screenHeight * 0.85 - systemOverhead))
        switch self {
        case .low: return min(136, maximum)
        case .medium:
            let native = KeyboardHeights.height(landscape: landscape) - (landscape ? 35.33 : 54)
            return min(native, maximum)
        case .full: return maximum
        }
    }

    public func stepped(up: Bool) -> Self {
        switch (self, up) {
        case (.low, true): .medium
        case (.medium, true): .full
        case (.full, false): .medium
        case (.medium, false): .low
        default: self
        }
    }

    public func swiped(dx: Double, dy: Double) -> Self {
        guard abs(dy) >= 24, abs(dy) > abs(dx) else { return self }
        return stepped(up: dy < 0)
    }

    public var cycled: Self { self == .full ? .low : stepped(up: true) }
}
