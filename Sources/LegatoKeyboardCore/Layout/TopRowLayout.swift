import Foundation

/// Which side of the top row the dictation key sits on (the app's Settings > Keyboard > Dictation key). The app writes it to
/// the App Group and the keyboard reads it there, so both agree; the layout mirrors. Right by default.
public enum DictationKeySide: String, Sendable, Equatable, CaseIterable {
    case left, right

    public static let preferenceKey = "keyboardDictationKeySide"
    public static let standard = DictationKeySide.right

    public static func stored(in defaults: UserDefaults) -> DictationKeySide {
        defaults.string(forKey: preferenceKey).flatMap(DictationKeySide.init(rawValue:)) ?? standard
    }

    public static func store(_ side: DictationKeySide, in defaults: UserDefaults) {
        defaults.set(side.rawValue, forKey: preferenceKey)
    }
}

/// How the return key is captioned: a glyph (return, send) fits a standard key; a word ("search", "go") needs more room.
public enum TopRowReturnStyle: Sendable, Equatable { case glyph, text }

/// The keyboard's top area (#315), in the keyboard view's coordinates: the dictation key on one side (`DictationKeySide`) and
/// the transcript beside it, across the rest of the width.
///
/// - Full: the dictation key is as wide as the native return key (`columnWidth`) and as tall as a grid key, one row pitch
///   above the grid (`KeyboardHeights.keyFaceTop`); the transcript spans the key's height (at least
///   `WordRowHeight.minimumRow`).
/// - Minimised: the same key on top, and under it delete and return (the globe key innermost when iOS asks for it), each as
///   wide as the grid's emoji key (`keyWidth`; a worded return caption gets ``textReturnWidth``) and stretched to fill the
///   column, which grows past `columnWidth` only when they need it. The transcript spans both rows.
///
/// The keys' touch areas reach the screen edge on their side and half the gap toward their neighbours; the dictation key's
/// reaches the top of the view and, on the full keyboard, down to where the grid's touch area starts.
public struct TopRowLayout: Sendable, Equatable {
    public enum Slot: Sendable, Equatable, Hashable { case dictation, globe, delete, returnKey }

    /// One key: the drawn face and the touch area around it.
    public struct Cell: Sendable, Equatable {
        public let slot: Slot
        public let face: KeyRect
        public let hit: KeyRect
    }

    /// The dictation key first, then the second row (minimised only) left to right.
    public let cells: [Cell]
    /// The transcript (the dictation preview or the suggestions), drawn and touched in this frame.
    public let transcript: KeyRect
    public let side: DictationKeySide

    public static let textReturnWidth = 60.0

    public func cell(_ slot: Slot) -> Cell? { cells.first { $0.slot == slot } }

    /// - Parameters:
    ///   - keyWidth: a standard key of the second row (the grid's emoji key).
    ///   - columnWidth: the dictation key's width (the grid's return key).
    ///   - scale: the vertical scale when the system grants less height than asked (`KeyGeometry.vScale`).
    public static func make(mode: KeyboardMode, side: DictationKeySide, width: Double, landscape: Bool, margin: Double, gap: Double,
                            keyWidth: Double, columnWidth: Double, showsGlobe: Bool = false, returnStyle: TopRowReturnStyle = .glyph,
                            scale: Double = 1) -> TopRowLayout {
        let faceTop = KeyboardHeights.keyFaceTop(landscape: landscape) * scale
        let keyHeight = KeyboardHeights.keyHeight(landscape: landscape) * scale
        let pitch = KeyboardHeights.rowPitch(landscape: landscape) * scale

        // The second row, from the transcript outward.
        var row: [(slot: Slot, width: Double)] = []
        if mode == .minimised {
            if showsGlobe { row.append((.globe, keyWidth)) }
            row.append((.delete, keyWidth))
            row.append((.returnKey, returnStyle == .text ? max(keyWidth, textReturnWidth) : keyWidth))
        }
        let natural = row.reduce(0) { $0 + $1.width } + Double(max(row.count - 1, 0)) * gap
        let column = max(columnWidth, natural)
        let stretch = row.isEmpty ? 0 : (column - natural) / Double(row.count)

        let right = side == .right
        let columnX = right ? width - margin - column : margin
        // Where the key column's touch area meets the transcript's: half a gap off the keys.
        let split = right ? columnX - gap / 2 : columnX + column + gap / 2
        // The key column's touch area across: from the split to the screen edge on its side.
        let columnHit = (x: right ? split : 0, width: right ? width - split : split)

        var cells: [Cell] = []
        let dictationFace = KeyRect(x: columnX, y: faceTop, width: column, height: keyHeight)
        let transcriptX = right ? 0 : split
        let transcriptWidth = right ? split : width - split
        let transcript: KeyRect
        switch mode {
        case .full:
            // Down to where the grid takes touches (`KeyGridView`: a gap above the first row).
            let bottom = KeyboardHeights.firstRowTop(landscape: landscape) * scale - gap
            cells.append(Cell(slot: .dictation, face: dictationFace,
                              hit: KeyRect(x: columnHit.x, y: 0, width: columnHit.width, height: bottom)))
            let height = max(keyHeight, WordRowHeight.minimumRow * scale)
            transcript = KeyRect(x: transcriptX, y: faceTop - (height - keyHeight) / 2, width: transcriptWidth, height: height)
        case .minimised:
            let between = faceTop + keyHeight + (pitch - keyHeight) / 2
            let bottom = KeyboardHeights.minimisedHeight(landscape: landscape) * scale
            cells.append(Cell(slot: .dictation, face: dictationFace,
                              hit: KeyRect(x: columnHit.x, y: 0, width: columnHit.width, height: between)))
            let ordered = right ? row : row.reversed()
            var x = columnX
            var faces: [(slot: Slot, face: KeyRect)] = []
            for key in ordered {
                let w = key.width + stretch
                faces.append((key.slot, KeyRect(x: x, y: faceTop + pitch, width: w, height: keyHeight)))
                x += w + gap
            }
            for (index, key) in faces.enumerated() {
                let hitX = index == 0 ? (right ? split : 0) : key.face.x - gap / 2
                let hitMaxX = index == faces.count - 1 ? (right ? width : split) : key.face.maxX + gap / 2
                cells.append(Cell(slot: key.slot, face: key.face,
                                  hit: KeyRect(x: hitX, y: between, width: hitMaxX - hitX, height: bottom - between)))
            }
            transcript = KeyRect(x: transcriptX, y: faceTop, width: transcriptWidth, height: pitch + keyHeight)
        }
        return TopRowLayout(cells: cells, transcript: transcript, side: side)
    }
}
