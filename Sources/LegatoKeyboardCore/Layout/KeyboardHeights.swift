import Foundation

/// iOS 26 prediction geometry. The system may add a rounded area above portrait extensions, counted
/// in Apple's 44 pt prediction view. Landscape adds none. On a phone it measured 0, 17 and about 33 pt,
/// and 0 and 17 in the same field, with the extension's settled geometry identical: it cannot be read,
/// so the words center in the extension's own row and never lean on that area.
public enum WordRowHeight {
    public static let visible = 44.0
    public static let portraitSystemTop = 17.0
    public static let portrait = visible - portraitSystemTop
    public static let strip = portrait

    public static func content(landscape: Bool) -> Double { landscape ? visible : portrait }

    /// Two lines of the dictation preview (#312) must fit the row as it is: the row never grows or shrinks for a take (the
    /// compact strip stays reachable, and the native prediction frame is its size). The text sits clear of the row's edges
    /// (`previewMinPadding`) with a little air between its lines (`previewLineSpacing`). The largest size of these whose two
    /// lines, the air and the padding fit; the line height is an ESTIMATE (1.2 x the size, SF's usual), not measured on a phone.
    public static let previewSizes: [Double] = [13, 12, 11, 10]
    public static func previewLineHeight(size: Double) -> Double { size * 1.2 }
    public static func previewLineSpacing(size: Double) -> Double { size * 0.1 }
    public static let previewMinPadding = 1.0
    public static func previewContentHeight(size: Double) -> Double { 2 * previewLineHeight(size: size) + previewLineSpacing(size: size) }
    public static func previewFontSize(rowHeight: Double) -> Double {
        previewSizes.first { previewContentHeight(size: $0) + 2 * previewMinPadding <= rowHeight } ?? previewSizes[previewSizes.count - 1]
    }
    /// The space above and below the two lines (balanced).
    public static func previewPadding(rowHeight: Double, size: Double) -> Double {
        max(0, (rowHeight - previewContentHeight(size: size)) / 2)
    }
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
