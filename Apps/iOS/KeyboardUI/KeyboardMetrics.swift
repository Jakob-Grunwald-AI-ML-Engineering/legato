import LegatoKeyboardCore
import UIKit

/// Geometry and colors of the Legato keyboard, matched to the iOS 26 system keyboard.
///
/// Measured, not guessed: the system keyboard (default, `en`, light and dark, portrait and landscape,
/// plus email, numbers and phone fields) was captured on the iPhone 17 Pro simulator (402 x 874 pt,
/// iOS 26.5, 3x) with a UI test that opened a text view and pressed keys while taking screenshots
/// (`XCUIScreen.screenshot`), and measured from the pixels. Reference values below are in points at
/// that size; they scale with the key width for other devices. Prediction rows also use native
/// dimensions; Legato adds one matching tool key row.
///
/// Portrait, 402 pt wide:
///  - Rows: first row top 52 pt under the keyboard top (the system's suggestion bar), pitch 54, key
///    height 43 (numpad 45.33). Side margin 6, gap 6, so a letter key is (W - 12 - 54) / 10 = 33.6 wide.
///  - Row 2 is indented half a pitch. Row 3: shift and delete 46 wide, the 7 letters centered
///    (13.67 gap); on the numbers page the 5 punctuation keys are 49.33 wide.
///  - Bottom row: "123" 44, emoji 43.33, space the rest, return 93 (numbers page: "ABC" 93.33, no
///    emoji). Email adds "@" and "." (43.33 each) around the space bar.
///  - Numpad: 3 columns 126.33 wide, margin 4.67, gap 6, key height 45.33.
///  - Key corner radius 8.5 (25 px), no shadow, no outline. Letters: SF 25 pt lowercase / 22 pt capitals, baseline 28 pt below the
///    key top; "123"/"ABC": 18 pt, baseline 27.3. Symbols (shift, delete, return, emoji): 17-20 pt boxes.
///  - Key fill light #FFFFFF, dark white at 16.5% over the keyboard; pressed function key light
///    #C5C5C9, dark white at 44%; return key with an action: system blue.
///  - Popup: head 57 wide (key + 23.4), 12 pt corner radius, top 66.3 above the key top, straight down
///    to 11 above the key top, then a 17 pt S-curve into the key's own width and down to the key
///    bottom; glyph SF 38.3 pt, baseline 47 below the head top. Fill as the key (dark: white 26%).
///  - Alternates strip: cells 37.3 wide x 47.7 high, 11.5 pad, strip 66.7 high ending 5 above the key
///    top, radius 12; the highlighted cell is system blue (0,136,255) with white text.
/// Landscape, 874 pt screen: side margin 79 including system insets, gap 6, key height 27.33, pitch 35.33, row 1 at 50.
///
/// Legato puts one top row above the native grid (#315): the dictation key, as wide as the return key and as tall as a grid
/// key, beside the transcript (`TopRowLayout`, `KeyboardHeights`). Minimised, delete and return go under the key.
struct KeyGeometry {
    let size: CGSize
    let landscapeScreenWidth: CGFloat?

    init(size: CGSize, landscapeScreenWidth: CGFloat? = nil) {
        self.size = size
        self.landscapeScreenWidth = landscapeScreenWidth
    }

    @MainActor static func screenWidth(in window: UIWindow?) -> CGFloat? {
        guard let bounds = window?.windowScene?.screen.bounds else { return nil }
        return max(bounds.width, bounds.height)
    }

    /// A phone is wider than 500 pt only in landscape. Never compare width with height: the keyboard is
    /// shorter than it is wide in both orientations.
    var landscape: Bool { Self.isLandscape(width: size.width) }
    static func isLandscape(width: CGFloat) -> Bool { width > 500 }

    /// The vertical metrics below are the measured ones at the requested height; when the keyboard gets
    /// less (a system that grants less height, a small phone), the rows shrink with it so every
    /// row stays inside the view. Never above 1: extra height stays empty under the rows.
    var vScale: CGFloat { vScale(for: .full) }

    /// The same for a layout's own requested height (the minimised keyboard is shorter).
    func vScale(for mode: KeyboardMode) -> CGFloat {
        guard size.height > 0 else { return 1 }
        return min(1, max(0.5, size.height / CGFloat(KeyboardHeights.requested(mode: mode, landscape: landscape))))
    }

    /// iOS may already inset the extension window (75 pt per side on iPhone 17).
    /// Subtract that inset while preserving the full-screen harness's 79 pt margin.
    var marginX: CGFloat {
        landscape ? CGFloat(KeyboardSideMargins.landscape(
            contentWidth: Double(size.width), screenWidth: landscapeScreenWidth.map(Double.init))) : 6.33
    }
    var gap: CGFloat { 6 }
    /// A letter key's width.
    var keyWidth: CGFloat { (size.width - 2 * marginX - 9 * gap) / 10 }
    var keyHeight: CGFloat { CGFloat(KeyboardHeights.keyHeight(landscape: landscape)) * vScale }
    var rowPitch: CGFloat { CGFloat(KeyboardHeights.rowPitch(landscape: landscape)) * vScale }
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
    var letterBaseline: CGFloat { (landscape ? 19.3 : 28.0) * vScale }
    var labelBaseline: CGFloat { (landscape ? 17.6 : 27.3) * vScale }
    /// Native portrait capitals are smaller than lowercase letters, on the same baseline.
    /// Symbols have no case and keep their original size.
    func letterSize(for text: String) -> CGFloat {
        let uppercaseLetter = text == text.uppercased() && text != text.lowercased()
        return landscape ? 22.2 : (uppercaseLetter ? 22 : 25)
    }
    var labelSize: CGFloat { landscape ? 16 : 18 }

    // MARK: Top row

    /// The top row (#315) for this keyboard: the dictation key on `side` beside the transcript; minimised, delete and return
    /// (and the globe key) under the key. The key is as wide as the native return key; the minimised keys as the emoji key.
    func topRow(mode: KeyboardMode, side: DictationKeySide, showsGlobe: Bool = false, returnStyle: TopRowReturnStyle = .glyph) -> TopRowLayout {
        TopRowLayout.make(mode: mode, side: side, width: Double(size.width), landscape: landscape, margin: Double(marginX), gap: Double(gap),
                          keyWidth: Double(smallKeyWidth), columnWidth: Double(wideKeyWidth), showsGlobe: showsGlobe,
                          returnStyle: returnStyle, scale: Double(vScale(for: mode)))
    }

    // MARK: Popups

    /// The popup's scale against portrait (the keys are shorter in landscape).
    var popupScale: CGFloat { CGFloat(KeyboardHeights.popupScale(landscape: landscape)) * vScale }
}

extension KeyRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// The key colors, light and dark, from the system keyboard.
enum KeyColors {
    static let key = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.165) : .white }
    static let pressed = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.44) : UIColor(red: 197 / 255, green: 197 / 255, blue: 201 / 255, alpha: 1)
    }
    /// Opaque popup surface: a native dark capture has a subtle material gradient around #333.
    /// Alpha here reveals the word and tool rows under the grid's popup drawing; clearing the
    /// grid's own backing does not clear those siblings. The grid must stay above them.
    static let popup = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.2, alpha: 1) : .white }
    static let ink = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
    static let accent = UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)
    static let highlight = UIColor(red: 0, green: 136 / 255, blue: 1, alpha: 1)
    static let suggestion = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.6) : UIColor(white: 0, alpha: 0.7) }
    static let divider = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(red: 208 / 255, green: 210 / 255, blue: 215 / 255, alpha: 1) }
    static let shadow = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.0) : UIColor(white: 0, alpha: 0.07) }
}
