import Foundation

/// Native prediction-row heights, in points.
public enum WordRowHeight {
    public static let strip = 44.0
    public static let portrait = 44.0
}

/// Predictions, one tool key row, then the unchanged native typing grid.
public enum KeyboardHeights {
    // The extension ends above iOS's globe/dictation area.
    private static let rowsBelow = 3 * 54.0 + 43 + 3

    public static func pillHeight(landscape: Bool) -> Double { landscape ? 27.33 : 43 }
    public static func pillGapToRow(landscape: Bool) -> Double { landscape ? 8 : 11 }
    public static func wordRowHeight(landscape: Bool) -> Double { WordRowHeight.portrait }

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
