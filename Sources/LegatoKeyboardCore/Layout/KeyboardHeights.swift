import Foundation

/// The dictation preview's type (#312): the largest size at which two lines fit the transcript band as it is (`TopRowLayout.transcript`).
/// The preview itself is taller (`TopRowLayout.preview`) and shows more lines at that size; the size never grows with it.
public enum WordRowHeight {
    /// The smallest transcript area: two lines of the smallest size with their air (2 x 13.2 + 1.1 + 2 x 1 = 29.5 pt). The
    /// full keyboard's top row is at least this tall (landscape keys are shorter).
    public static let minimumRow = 30.0

    /// The largest size whose two lines, a line spacing of 0.1 x the size and `previewMinPadding` above and below fit: 13 pt in
    /// the portrait top row (43 pt: 31.2 + 1.3 + 2) and minimised, 11 pt in landscape (30 pt). The line height is an ESTIMATE
    /// (1.2 x the size, SF's usual), not measured.
    public static let previewSizes: [Double] = [13, 12, 11]
    public static func previewLineHeight(size: Double) -> Double { size * 1.2 }
    public static func previewLineSpacing(size: Double) -> Double { 0.1 * size }
    public static let previewMinPadding = 1.0
    public static func previewContentHeight(size: Double) -> Double { 2 * previewLineHeight(size: size) + previewLineSpacing(size: size) }
    public static func previewFontSize(rowHeight: Double) -> Double {
        previewSizes.first { previewContentHeight(size: $0) + 2 * previewMinPadding <= rowHeight } ?? previewSizes[previewSizes.count - 1]
    }
}

/// The keyboard's heights (#315): one top row (the dictation key beside the transcript) above the unchanged native typing
/// grid, or minimised to two rows of keys beside the transcript.
public enum KeyboardHeights {
    public static func keyHeight(landscape: Bool) -> Double { landscape ? 27.33 : 43 }
    public static func rowPitch(landscape: Bool) -> Double { landscape ? 35.33 : 54 }
    /// Under the last row of keys, as on the native keyboard.
    public static func bottomGap(landscape: Bool) -> Double { landscape ? 4 : 3 }

    /// The key popup's scale against portrait (the landscape keys are shorter).
    public static func popupScale(landscape: Bool) -> Double { landscape ? 0.78 : 1 }
    /// How far a key's popup head reaches above its key's top: one row pitch plus 12.3 pt (measured, `KeyboardMetrics`).
    public static func popupReach(landscape: Bool) -> Double { rowPitch(landscape: landscape) + 12.3 * popupScale(landscape: landscape) }

    /// The first row of the typing grid sits as high as its popups allow: an extension cannot draw above its own view, so the
    /// top row's letter popups must fit (67 pt portrait, 45 landscape). The top row's key sits one row pitch above it.
    public static func firstRowTop(landscape: Bool) -> Double { popupReach(landscape: landscape).rounded(.up) }

    /// The top of the top row's key faces, in both layouts: one pitch above the grid (13 pt portrait, 9.67 landscape).
    public static func keyFaceTop(landscape: Bool) -> Double { firstRowTop(landscape: landscape) - rowPitch(landscape: landscape) }

    /// The full keyboard: the top row, then the native grid (275 pt portrait).
    public static func height(landscape: Bool) -> Double {
        firstRowTop(landscape: landscape) + 3 * rowPitch(landscape: landscape) + keyHeight(landscape: landscape) + bottomGap(landscape: landscape)
    }

    /// Minimised: the dictation key's row and one more row of keys (113 pt portrait).
    public static func minimisedHeight(landscape: Bool) -> Double {
        keyFaceTop(landscape: landscape) + rowPitch(landscape: landscape) + keyHeight(landscape: landscape) + bottomGap(landscape: landscape)
    }

    /// The height the keyboard asks the system for in `mode`.
    public static func requested(mode: KeyboardMode, landscape: Bool) -> Double {
        mode == .minimised ? minimisedHeight(landscape: landscape) : height(landscape: landscape)
    }
}

/// Horizontal inset still needed after iOS has inset the extension's content window.
public enum KeyboardSideMargins {
    public static func landscape(contentWidth: Double, screenWidth: Double?) -> Double {
        let systemInset = max(0, ((screenWidth ?? contentWidth) - contentWidth) / 2)
        return max(4, 79 - systemInset)
    }
}
