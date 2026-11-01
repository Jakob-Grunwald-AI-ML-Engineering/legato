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

/// The composer's height. Portrait: 55 % of the screen, kept within 50-60 % and inside the room the
/// system leaves; landscape keeps the compact height. The ABC surface keeps `KeyboardHeights.height`.
public enum ComposerKeyboardLayout {
    public static let portraitFraction = 0.55
    public static let fractionRange = 0.5...0.6
    /// What the compact (landscape) composer adds to the typing keyboard's height.
    public static let additionalComposerHeight = 28.0
    /// The tool row at the bottom of the composer.
    public static func toolRowHeight(landscape: Bool) -> Double { landscape ? 35.33 : 54 }

    public static func typingHeight(landscape: Bool) -> Double {
        KeyboardHeights.height(landscape: landscape) - toolRowHeight(landscape: landscape)
    }
    /// `fraction` is clamped to 50-60 %.
    public static func height(screenHeight: Double, systemOverhead: Double, landscape: Bool = false,
                              fraction: Double = portraitFraction) -> Double {
        let room = max(0, screenHeight - systemOverhead - 60)
        if landscape { return min(typingHeight(landscape: true) + additionalComposerHeight, room) }
        let clamped = min(max(fraction, fractionRange.lowerBound), fractionRange.upperBound)
        return min(screenHeight * clamped, room)
    }
}
