import LegatoKeyboardCore
import SwiftUI
import UIKit

/// One touch surface for all typing keys: it draws the keys, maps touches with `KeyHitTester`, shows the
/// key popup and the long-press alternates, and reports to `TypingModel`. The globe key is a view on top
/// of it (it needs the system's own control) and is skipped here. Look and geometry: `KeyboardMetrics.swift`.
///
/// Touch-down: feedback, the popup (delete acts at once). Touch-up: the key under the finger is typed,
/// so a finger can slide between letters. A hold of 0.4 s on a key with alternates opens the strip; the
/// finger then picks by sliding along it.
@MainActor
final class KeyGridView: UIView {
    static let holdDelay: Duration = .milliseconds(400)
    private var overlayKeys: Set<String> = ["globe"]

    weak var typing: TypingModel?

    private(set) var layout = TypingLayout(rows: [])
    private(set) var presentation = KeyPresentation()

    private var frames: [String: CGRect] = [:]
    private var keys: [String: Key] = [:]
    private var tester = KeyHitTester(frames: [])
    private var builtFor: CGSize = .zero
    private var touchStates: [ObjectIdentifier: TouchState] = [:]
    private var symbolCache: [String: UIImage] = [:]

    /// One finger on the grid.
    private final class TouchState {
        let origin: Key
        var current: Key?
        var point: CGPoint
        var hold: Task<Void, Never>?
        /// The strip's cells (the alternates with the key's own letter at `baseIndex`); empty until it opens.
        var cells: [String] = []
        var baseIndex = 0
        var selected = 0

        init(origin: Key, point: CGPoint) {
            self.origin = origin
            current = origin
            self.point = point
        }

        var picking: Bool { !cells.isEmpty }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var geometry: KeyGeometry {
        KeyGeometry(size: bounds.size, landscapeScreenWidth: KeyGeometry.screenWidth(in: window))
    }

    /// The top bar (suggestions, mic pill) lies under this view; only the key rows take touches. A touch
    /// that began on a key keeps coming here wherever it moves (the popups reach into the bar).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        point.y >= geometry.firstRowTop - geometry.gap && super.point(inside: point, with: event)
    }

    func apply(layout: TypingLayout, presentation: KeyPresentation, emojiSystemSwitcher: Bool) {
        let overlays: Set<String> = emojiSystemSwitcher ? ["globe", "emoji"] : ["globe"]
        let overlaysChanged = overlays != overlayKeys
        overlayKeys = overlays
        let layoutChanged = layout != self.layout
        guard layoutChanged || overlaysChanged || presentation != self.presentation else { return }
        self.layout = layout
        self.presentation = presentation
        if layoutChanged || overlaysChanged { rebuild() } else { rebuildAccessibility() }
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != builtFor { rebuild() }
        #if DEBUG
        KeyboardGeometryLog.report(grid: self)
        #endif
    }

    #if DEBUG
    /// The grid's key frames, for `KeyboardGeometryLog`.
    var keyFrames: [String: CGRect] { frames }
    #endif

    private func rebuild() {
        builtFor = bounds.size
        let all = layout.frames(in: bounds.size, landscapeScreenWidth: KeyGeometry.screenWidth(in: window))
        frames = Dictionary(all.map { ($0.id, $0.cgRect) }, uniquingKeysWith: { a, _ in a })
        keys = Dictionary(layout.rows.flatMap(\.keys).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tester = KeyHitTester(frames: all.filter { !overlayKeys.contains($0.id) })
        rebuildAccessibility()
        setNeedsDisplay()
    }

    // MARK: Accessibility

    private final class KeyElement: UIAccessibilityElement {
        var activate: (() -> Void)?
        override func accessibilityActivate() -> Bool {
            activate?()
            return activate != nil
        }
    }

    private func rebuildAccessibility() {
        let typing = typing
        accessibilityElements = layout.rows.flatMap(\.keys).compactMap { key -> UIAccessibilityElement? in
            guard !overlayKeys.contains(key.id), let frame = frames[key.id] else { return nil }
            let element = KeyElement(accessibilityContainer: self)
            element.accessibilityLabel = accessibilityName(key)
            element.accessibilityIdentifier = Self.identifier(key)
            element.accessibilityTraits = .keyboardKey
            element.accessibilityFrameInContainerSpace = frame
            element.activate = { typing?.press(keyID: key.id) }
            return element
        }
    }

    private static func identifier(_ key: Key) -> String {
        if case .character(let c) = key.action { return "key.\(c)" }
        if case .modeSwitch(let p) = key.action { return "key.mode.\(p)" }
        return "key.\(key.id)"
    }

    private func accessibilityName(_ key: Key) -> String {
        switch key.action {
        case .character(let c): presentation.uppercase ? c.uppercased() : c
        case .shift: "shift"
        case .delete: "delete"
        case .space: presentation.spaceLabel
        case .returnKey: presentation.returnLabel
        case .emoji: "emoji"
        case .modeSwitch, .globe, .mic: key.label
        }
    }

    // MARK: Touches

    private func slidable(_ key: Key) -> Bool {
        switch key.action {
        case .character, .space: true
        default: false
        }
    }

    private func key(at point: CGPoint) -> Key? {
        tester.key(at: KeyPoint(x: point.x, y: point.y)).flatMap { keys[$0] }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let key = key(at: point) else { continue }
            let state = TouchState(origin: key, point: point)
            touchStates[ObjectIdentifier(touch)] = state
            typing?.feedback.tick()
            typing?.keyDown(key)
            scheduleHold(state)
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = touchStates[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            state.point = point
            if state.picking {
                let selected = nearestCell(state)
                if selected != state.selected { typing?.feedback.tick() }
                state.selected = selected
            } else if slidable(state.origin) {
                let hit = key(at: point).flatMap { slidable($0) ? $0 : nil }
                if hit?.id != state.current?.id {
                    state.current = hit
                    scheduleHold(state)
                    if hit != nil { typing?.feedback.tick() }
                }
            }
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = touchStates.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            state.hold?.cancel()
            if state.picking {
                let pick = state.selected == state.baseIndex ? nil : state.cells[state.selected]
                typing?.keyUp(state.origin, alternate: pick)
            } else if let key = state.current {
                typing?.keyUp(key)
            } else {
                typing?.keyCancelled(state.origin)
            }
        }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = touchStates.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            state.hold?.cancel()
            typing?.keyCancelled(state.origin)
        }
        setNeedsDisplay()
    }

    private func scheduleHold(_ state: TouchState) {
        state.hold?.cancel()
        state.hold = nil
        guard let key = state.current, let alternates = typing?.alternates(for: key), !alternates.isEmpty,
              let own = typing?.output(of: key)
        else { return }
        state.hold = Task { [weak self, weak state] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let self, let state, let frame = self.frames[key.id] else { return }
            let pad = Self.stripPad, pitch = Self.stripPitch
            let minX = Self.stripInset + pad
            let base = min(max(Int(((frame.midX - minX) / pitch - 0.5).rounded()), 0), alternates.count)
            state.baseIndex = base
            state.cells = Array(alternates[..<base]) + [own] + Array(alternates[base...])
            state.selected = base
            self.typing?.feedback.tick()
            self.setNeedsDisplay()
        }
    }

    // MARK: Alternates strip (measured: see KeyboardMetrics.swift)

    private static let stripInset: CGFloat = 4
    private static let stripPad: CGFloat = 11.5
    private static let stripPitch: CGFloat = 37.3

    private func stripRect(_ state: TouchState) -> CGRect {
        guard let key = frames[state.current?.id ?? state.origin.id] else { return .zero }
        let width = CGFloat(state.cells.count) * Self.stripPitch + 2 * Self.stripPad
        let base = CGFloat(state.baseIndex) + 0.5
        var x = key.midX - Self.stripPad - base * Self.stripPitch
        x = min(max(x, Self.stripInset), bounds.width - Self.stripInset - width)
        return CGRect(x: x, y: key.minY - 71.7, width: width, height: 66.7)
    }

    private func cellRect(_ state: TouchState, _ index: Int) -> CGRect {
        let strip = stripRect(state)
        return CGRect(x: strip.minX + Self.stripPad + CGFloat(index) * Self.stripPitch, y: strip.minY + 9, width: Self.stripPitch, height: 47.7)
    }

    private func nearestCell(_ state: TouchState) -> Int {
        state.cells.indices.min {
            abs(cellRect(state, $0).midX - state.point.x) < abs(cellRect(state, $1).midX - state.point.x)
        } ?? 0
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let trait = traitCollection
        let held = Set(touchStates.values.compactMap { $0.current?.id })
        for key in layout.rows.flatMap(\.keys) {
            guard !overlayKeys.contains(key.id), let frame = frames[key.id] else { continue }
            drawKey(key, in: frame, pressed: held.contains(key.id), ctx: ctx, trait: trait)
        }
        for state in touchStates.values {
            if state.picking {
                drawStrip(state, ctx: ctx, trait: trait)
            } else if let key = state.current, case .character = key.action, let frame = frames[key.id] {
                drawPopup(for: key, frame: frame, ctx: ctx, trait: trait)
            }
        }
    }

    private func fill(_ path: CGPath, color: UIColor, ctx: CGContext, trait: UITraitCollection, clearFirst: Bool = false) {
        if clearFirst {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.setFillColor(color.resolvedColor(with: trait).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    private func drawKey(_ key: Key, in frame: CGRect, pressed: Bool, ctx: CGContext, trait: UITraitCollection) {
        let p = presentation
        let g = geometry
        var color = pressed ? KeyColors.pressed : KeyColors.key
        var ink = KeyColors.ink
        if case .character = key.action { color = KeyColors.key }  // a letter's press is the popup
        if case .space = key.action, pressed { color = KeyColors.pressed }
        if key.action == .returnKey {
            if p.returnProminent && p.returnEnabled {
                color = pressed ? KeyColors.accent.withAlphaComponent(0.7) : KeyColors.accent
                ink = .white
            }
            if !p.returnEnabled { ink = ink.withAlphaComponent(0.3) }
        }
        fill(CGPath(roundedRect: frame, cornerWidth: g.radius, cornerHeight: g.radius, transform: nil), color: color, ctx: ctx, trait: trait)

        let inkColor = ink.resolvedColor(with: trait)
        switch key.action {
        case .character(let c):
            let text = p.uppercase ? c.uppercased() : c
            let numpad = layout.rows.first?.kind == .numpad
            if numpad {
                drawText(text, centerX: frame.midX, baseline: frame.minY + 26.5, size: 28, weight: .regular, color: inkColor)
                if let sub = TypingLayout.sublabel(c) {
                    drawText(sub, centerX: frame.midX, baseline: frame.maxY - 7.5, size: 10.5, weight: .semibold, color: inkColor, kern: 2.2)
                }
                if key.id == "char:+" { drawText("+", centerX: frame.midX, baseline: frame.minY + 30, size: 30, weight: .regular, color: inkColor) }
            } else {
                drawText(text, centerX: frame.midX, baseline: frame.minY + g.letterBaseline, size: g.letterSize(for: text), weight: .regular, color: inkColor)
            }
        case .returnKey:
            if let symbol = KeyLabels.returnSymbol(for: p.returnLabel) {
                drawSymbol(symbol.name, in: frame, color: inkColor, weight: symbol.weight)
            } else {
                drawText(p.returnLabel, centerX: frame.midX, baseline: frame.minY + g.labelBaseline, size: 17, weight: .regular, color: inkColor)
            }
        case .modeSwitch(let target):
            let label = target == .letters ? "ABC" : key.label
            let small = label == "#+="
            drawText(label, centerX: frame.midX, baseline: frame.minY + g.labelBaseline, size: small ? g.labelSize - 3 : g.labelSize, weight: .regular, color: inkColor)
        case .shift:
            drawSymbol(p.shift == .capsLock ? "capslock.fill" : p.shift == .once ? "shift.fill" : "shift", in: frame, color: inkColor)
        case .delete:
            drawSymbol(pressed ? "delete.left.fill" : "delete.left", in: frame, color: inkColor)
        case .emoji:
            if layout.rows.first?.kind != .numpad { drawSymbol("face.smiling", in: frame, color: inkColor) }
        case .space, .globe, .mic:
            break
        }
    }

    /// Draws `text` centered on `centerX` with its baseline at `baseline`.
    private func drawText(
        _ text: String, centerX: CGFloat, baseline: CGFloat, size: CGFloat, weight: UIFont.Weight, color: UIColor, kern: CGFloat = 0
    ) {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        let width = (text as NSString).size(withAttributes: attributes).width - kern
        (text as NSString).draw(at: CGPoint(x: centerX - width / 2, y: baseline - font.ascender), withAttributes: attributes)
    }

    private func drawSymbol(_ name: String, in rect: CGRect, color: UIColor, size: CGFloat = 19, weight: UIImage.SymbolWeight = .regular) {
        let cacheKey = "\(name)-\(size)-\(color.hash)"
        let image: UIImage
        if let cached = symbolCache[cacheKey] {
            image = cached
        } else {
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: weight)
            guard let base = UIImage(systemName: name, withConfiguration: config) else { return }
            image = base.withTintColor(color, renderingMode: .alwaysOriginal)
            symbolCache[cacheKey] = image
        }
        image.draw(at: CGPoint(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2))
    }

    /// The iOS popup: a head wider than the key, over the row above, that narrows into the key.
    private func popupPath(for frame: CGRect) -> CGPath {
        let g = geometry
        let s = g.popupScale
        let headWidth = frame.width + 23.4
        let margin = g.marginX
        var left = frame.minX - 11.7
        left = min(max(left, margin), bounds.width - margin - headWidth)
        let right = left + headWidth
        let top = frame.minY - (g.rowPitch + 12.3 * s)
        let neckStart = frame.minY - (g.rowPitch - g.keyHeight)
        let neckEnd = frame.minY + 6 * s
        let radius = 12 * s
        let r = g.radius
        let path = UIBezierPath()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addArc(withCenter: CGPoint(x: right - radius, y: top + radius), radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: right, y: neckStart))
        // Right neck, into the key's right edge.
        let mid = (neckStart + neckEnd) / 2
        path.addCurve(to: CGPoint(x: frame.maxX, y: neckEnd), controlPoint1: CGPoint(x: right, y: mid), controlPoint2: CGPoint(x: frame.maxX, y: mid))
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - r))
        path.addArc(withCenter: CGPoint(x: frame.maxX - r, y: frame.maxY - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: frame.minX + r, y: frame.maxY))
        path.addArc(withCenter: CGPoint(x: frame.minX + r, y: frame.maxY - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: frame.minX, y: neckEnd))
        path.addCurve(to: CGPoint(x: left, y: neckStart), controlPoint1: CGPoint(x: frame.minX, y: mid), controlPoint2: CGPoint(x: left, y: mid))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addArc(withCenter: CGPoint(x: left + radius, y: top + radius), radius: radius, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        path.close()
        return path.cgPath
    }

    private func drawPopup(for key: Key, frame: CGRect, ctx: CGContext, trait: UITraitCollection) {
        guard let text = typing?.output(of: key) else { return }
        let g = geometry
        let path = popupPath(for: frame)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 1.5, color: KeyColors.shadow.resolvedColor(with: trait).cgColor)
        fill(path, color: KeyColors.popup, ctx: ctx, trait: trait, clearFirst: true)
        ctx.restoreGState()
        let top = frame.minY - (g.rowPitch + 12.3 * g.popupScale)
        let headWidth = frame.width + 23.4
        let margin = g.marginX
        let left = min(max(frame.minX - 11.7, margin), bounds.width - margin - headWidth)
        drawText(
            text, centerX: left + headWidth / 2, baseline: top + 47 * g.popupScale, size: 38.3 * g.popupScale, weight: .regular,
            color: KeyColors.ink.resolvedColor(with: trait))
    }

    private func drawStrip(_ state: TouchState, ctx: CGContext, trait: UITraitCollection) {
        let strip = stripRect(state)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 1.5, color: KeyColors.shadow.resolvedColor(with: trait).cgColor)
        fill(CGPath(roundedRect: strip, cornerWidth: 12, cornerHeight: 12, transform: nil), color: KeyColors.popup, ctx: ctx, trait: trait, clearFirst: true)
        ctx.restoreGState()
        for (i, text) in state.cells.enumerated() {
            let cell = cellRect(state, i)
            var ink = KeyColors.ink.resolvedColor(with: trait)
            if i == state.selected {
                fill(CGPath(roundedRect: cell, cornerWidth: 10, cornerHeight: 10, transform: nil), color: KeyColors.highlight, ctx: ctx, trait: trait)
                ink = .white
            }
            drawText(text, centerX: cell.midX, baseline: cell.minY + 31, size: 24, weight: .regular, color: ink)
        }
    }
}

/// The key grid in SwiftUI. Everything it shows arrives as values, so SwiftUI redraws it when they change.
struct KeyGrid: UIViewRepresentable {
    let typing: TypingModel
    let layout: TypingLayout
    let presentation: KeyPresentation
    let appearance: UIUserInterfaceStyle
    var emojiSystemSwitcher = false

    func makeUIView(context: Context) -> KeyGridView {
        let view = KeyGridView()
        view.typing = typing
        return view
    }

    func updateUIView(_ view: KeyGridView, context: Context) {
        view.overrideUserInterfaceStyle = appearance
        view.apply(layout: layout, presentation: presentation, emojiSystemSwitcher: emojiSystemSwitcher)
    }
}
