import LegatoKeyboardCore
import UIKit

/// Geometry and colors of the Legato keyboard, matched to the iOS 26 system keyboard.
///
/// Measured, not guessed: the system keyboard (default, `en`, light and dark, portrait and landscape,
/// plus email, numbers and phone fields) was captured on the iPhone 17 Pro simulator (402 x 874 pt,
/// iOS 26.5, 3x) with a UI test that opened a text view and pressed keys while taking screenshots
/// (`XCUIScreen.screenshot`), and measured from the pixels. Reference values below are in points at
/// that size; they scale with the key width for other devices. The top bar (suggestions and the mic
/// pill) follows Superwhisper's iOS keyboard (references from the product owner), whose key rows are
/// the system's own.
///
/// Portrait, 402 pt wide:
///  - Rows: first row top 51 pt under the keyboard top (the system's suggestion bar), pitch 54, key
///    height 43 (numpad 45.33). Side margin 6, gap 6, so a letter key is (W - 12 - 54) / 10 = 33.6 wide.
///  - Row 2 is indented half a pitch. Row 3: shift and delete 46 wide, the 7 letters centered
///    (13.67 gap); on the numbers page the 5 punctuation keys are 49.33 wide.
///  - Bottom row: "123" 44, emoji 43.33, space the rest, return 93 (numbers page: "ABC" 93.33, no
///    emoji). Email adds "@" and "." (43.33 each) around the space bar.
///  - Numpad: 3 columns 126.33 wide, margin 4.67, gap 6, key height 45.33.
///  - Key corner radius 8.5 (25 px), no shadow, no outline. Letters: SF 25 pt, baseline 28 pt below the
///    key top; "123"/"ABC": 18 pt, baseline 27.3. Symbols (shift, delete, return, emoji): 17-20 pt boxes.
///  - Key fill light #FFFFFF, dark white at 16.5% over the keyboard; pressed function key light
///    #C5C5C9, dark white at 44%; return key with an action: system blue.
///  - Popup: head 57 wide (key + 23.4), 12 pt corner radius, top 66.3 above the key top, straight down
///    to 11 above the key top, then a 17 pt S-curve into the key's own width and down to the key
///    bottom; glyph SF 38.3 pt, baseline 47 below the head top. Fill as the key (dark: white 26%).
///  - Alternates strip: cells 37.3 wide x 47.7 high, 11.5 pad, strip 66.7 high ending 5 above the key
///    top, radius 12; the highlighted cell is system blue (0,136,255) with white text.
/// Landscape, 874 pt wide: side margin 79, gap 6, key height 25.33, pitch 35.33, row 1 at 51.
///
/// Legato's top area (the vertical numbers are `KeyboardHeights`, tested in LegatoKeyboardCore): the mic
/// pill 81 x 43.3 pt (portrait), 14.3 from the right edge and 15.7 above the first row, follows
/// Superwhisper's iOS keyboard.
///  - Portrait: the word row (three slots, "2 | 1 | 3", 24 pt dividers) is 32 pt high across the top. Below
///    it, the hotkey bar (⌄ ↶ ↷ Refine) fills the space left of the pill. The pill's top is 32 pt down, so the
///    first row sits at 91, not at the 86 it would without the word row: the keyboard is 306 pt high.
///  - Landscape: one row, as high as the pill (34 pt): hotkeys, then the word slots, then the pill. The
///    first row is at 51 and the keyboard 190 pt high, as before; below 70 pt a slot, only the best word shows.
///  - Strip: the word row (30 pt) is a row of its own above the strip's row (`StripHeight.requested`).
struct KeyGeometry {
    let size: CGSize

    /// A phone is wider than 500 pt only in landscape. Never compare width with height: the keyboard is
    /// shorter than it is wide in both orientations.
    var landscape: Bool { Self.isLandscape(width: size.width) }
    static func isLandscape(width: CGFloat) -> Bool { width > 500 }

    /// The vertical metrics below are the measured ones at the requested height; when the keyboard gets
    /// less (a system that grants less height, a small phone), rows, bar and pill shrink with it so every
    /// row stays inside the view. Never above 1: extra height stays empty under the rows.
    var vScale: CGFloat {
        guard size.height > 0 else { return 1 }
        return min(1, max(0.5, size.height / Self.height(landscape: landscape)))
    }

    var marginX: CGFloat { landscape ? 79 : 6.33 }
    var gap: CGFloat { 6 }
    /// A letter key's width.
    var keyWidth: CGFloat { (size.width - 2 * marginX - 9 * gap) / 10 }
    var keyHeight: CGFloat { (landscape ? 25.33 : 43) * vScale }
    var rowPitch: CGFloat { (landscape ? 35.33 : 54) * vScale }
    /// Distance from the top of the keyboard view to the first row.
    var firstRowTop: CGFloat { Self.firstRowTop(landscape: landscape) * vScale }
    static let keyRadius: CGFloat = 8.5
    var radius: CGFloat { Self.keyRadius }

    static func firstRowTop(landscape: Bool) -> CGFloat { CGFloat(KeyboardHeights.firstRowTop(landscape: landscape)) }
    static func height(landscape: Bool) -> CGFloat { CGFloat(KeyboardHeights.height(landscape: landscape)) }

    /// Key widths relative to the portrait or landscape reference.
    private var unit: CGFloat { keyWidth / (landscape ? 66.2 : 33.6) }
    var functionWidth: CGFloat { (landscape ? 88 : 46) * unit }
    var punctuationWidth: CGFloat { (landscape ? 66.2 : 49.33) * unit }
    var modeKeyWidth: CGFloat { (landscape ? 66.33 : 44) * unit }
    var wideKeyWidth: CGFloat { (landscape ? 138.33 : 93) * unit }
    var smallKeyWidth: CGFloat { (landscape ? 66 : 43.33) * unit }
    var numpadKeyHeight: CGFloat { landscape ? keyHeight : 45.33 * vScale }

    /// Letter and label baselines below the key top.
    var letterBaseline: CGFloat { (landscape ? 18.3 : 28.0) * vScale }
    var labelBaseline: CGFloat { (landscape ? 17.6 : 27.3) * vScale }
    /// Landscape (measured): x-height 11.3 pt against 12.7 pt in portrait.
    var letterSize: CGFloat { landscape ? 22.2 : 25 }
    var labelSize: CGFloat { landscape ? 16 : 18 }

    // MARK: Top bar

    var pillSize: CGSize { CGSize(width: 81, height: CGFloat(KeyboardHeights.pillHeight(landscape: landscape)) * vScale) }
    var pillFrame: CGRect {
        let h = pillSize.height
        let gapToRow = CGFloat(KeyboardHeights.pillGapToRow(landscape: landscape)) * vScale
        return CGRect(x: size.width - (landscape ? marginX : 14.3) - pillSize.width, y: firstRowTop - gapToRow - h, width: pillSize.width, height: h)
    }
    /// The word row's own height (portrait; in landscape the word slots share the pill's row).
    var wordRowHeight: CGFloat { CGFloat(KeyboardHeights.wordRowHeight(landscape: landscape)) * vScale }
    private var barLeft: CGFloat { landscape ? marginX + 7.7 : 13.7 }
    /// Landscape, where the hotkeys take only what they need: the collapse key 44 wide, the three others 76 ("Refine" fits).
    private static let landscapeHotkeyWidth: CGFloat = 76

    /// Where the hotkeys go: left of the pill, in the pill's row. In landscape a fixed width for `buttons` (3, or 4 with the collapse key).
    func hotkeyFrame(buttons: Int) -> CGRect {
        let pill = pillFrame
        let width = landscape ? CGFloat(buttons - 3) * 44 + 3 * Self.landscapeHotkeyWidth : pill.minX - barLeft
        return CGRect(x: barLeft, y: pill.minY, width: width, height: pill.height)
    }

    /// Where the word slots go: portrait, the row across the top; landscape, between the hotkeys and the pill.
    func wordRowFrame(buttons: Int) -> CGRect {
        guard landscape else {
            return CGRect(x: barLeft, y: 0, width: size.width - 2 * barLeft, height: wordRowHeight)
        }
        let pill = pillFrame
        let left = hotkeyFrame(buttons: buttons).maxX + 8
        return CGRect(x: left, y: pill.minY, width: max(pill.minX - 8 - left, 0), height: pill.height)
    }


    // MARK: Popups

    /// The popup's scale against portrait (the keys are shorter in landscape).
    var popupScale: CGFloat { (landscape ? 0.78 : 1) * vScale }
}

/// The key colors, light and dark, from the system keyboard.
enum KeyColors {
    static let key = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.165) : .white }
    static let pressed = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.44) : UIColor(red: 197 / 255, green: 197 / 255, blue: 201 / 255, alpha: 1)
    }
    /// The popup (callout) body: the key color; dark: a bit lighter.
    static let popup = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.26) : .white }
    static let ink = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
    static let accent = UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)
    static let highlight = UIColor(red: 0, green: 136 / 255, blue: 1, alpha: 1)
    static let suggestion = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.6) : UIColor(white: 0, alpha: 0.7) }
    static let divider = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(red: 208 / 255, green: 210 / 255, blue: 215 / 255, alpha: 1) }
    static let shadow = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.0) : UIColor(white: 0, alpha: 0.07) }
}
