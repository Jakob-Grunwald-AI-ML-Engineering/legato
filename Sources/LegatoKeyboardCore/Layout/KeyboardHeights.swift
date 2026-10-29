import Foundation

/// How tall the word row is, in points.
public enum WordRowHeight {
    /// Above the compact strip.
    public static let strip = 40.0
    /// Above the hotkey bar and the pill on the portrait keyboard.
    public static let portrait = 32.0
}

/// The full keyboard's vertical layout, from the measured system-keyboard numbers (see `KeyGeometry`):
/// the pill is 43.3 pt (portrait) and sits 15.7 pt above the first row. In portrait the word row goes
/// above the hotkey bar and the pill, so the first row moves down by what the word row needs beyond the
/// space already above the pill. Landscape keeps one row (hotkeys, word slots and pill side by side).
public enum KeyboardHeights {
    /// Portrait first row top before the word row (the system's suggestion bar height).
    private static let baseFirstRowTop = 86.0
    // The real extension ends above iOS's globe/dictation area. A 3 pt bottom gap
    // aligns the key faces with the native iOS 26.5 keyboard (402 pt portrait).
    private static let rowsBelow = 3 * 54.0 + 43 + 3

    public static func pillHeight(landscape: Bool) -> Double { landscape ? 34 : 43.3 }
    public static func pillGapToRow(landscape: Bool) -> Double { landscape ? 9 : 15.7 }

    /// The word row's own height: portrait only; landscape has no row of its own.
    public static func wordRowHeight(landscape: Bool) -> Double { landscape ? 0 : WordRowHeight.portrait }

    /// Distance from the keyboard top to the first key row.
    public static func firstRowTop(landscape: Bool) -> Double {
        guard !landscape else { return 51 }
        let pillTop = baseFirstRowTop - pillGapToRow(landscape: false) - pillHeight(landscape: false)
        return baseFirstRowTop + max(0, wordRowHeight(landscape: false) - pillTop)
    }

    /// The keyboard's requested height.
    public static func height(landscape: Bool) -> Double {
        landscape ? 51 + 3 * 35.33 + 27.33 + 4 : firstRowTop(landscape: false) + rowsBelow
    }
}

/// Horizontal inset still needed after iOS has inset the extension's content window.
public enum KeyboardSideMargins {
    public static func landscape(contentWidth: Double, screenWidth: Double?) -> Double {
        let systemInset = max(0, ((screenWidth ?? contentWidth) - contentWidth) / 2)
        return max(4, 79 - systemInset)
    }
}
