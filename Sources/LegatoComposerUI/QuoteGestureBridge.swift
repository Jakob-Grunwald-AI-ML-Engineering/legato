#if canImport(UIKit)
import SwiftUI
import UIKit

/// A native long press yields to quick scrolls and tracks a quote after deliberate recognition.
struct QuoteGestureBridge: UIViewRepresentable {
    var reservedHeight: CGFloat
    var canBegin: @MainActor (CGPoint) -> Bool
    var began: @MainActor (CGPoint) -> Void
    var changed: @MainActor (CGPoint) -> Void
    var ended: @MainActor (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.install = { [weak coordinator = context.coordinator] view in coordinator?.install(from: view) }
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) { context.coordinator.input = self; context.coordinator.install(from: view) }
    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) { coordinator.detach() }
    final class ProbeView: UIView {
        var install: ((UIView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); install?(self) }
        override func layoutSubviews() { super.layoutSubviews(); install?(self) }
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var input: QuoteGestureBridge
        weak var scroll: UIScrollView?
        private lazy var press: UILongPressGestureRecognizer = {
            let value = UILongPressGestureRecognizer(target: self, action: #selector(handle))
            value.minimumPressDuration = 0.3; value.allowableMovement = 12
            value.cancelsTouchesInView = true; value.delegate = self
            return value
        }()
        init(_ input: QuoteGestureBridge) { self.input = input }
        func install(from view: UIView) {
            var parent = view.superview
            while let current = parent, !(current is UIScrollView) { parent = current.superview }
            guard let target = parent as? UIScrollView, target !== scroll else { return }
            detach(); scroll = target; target.addGestureRecognizer(press)
            // Movement fails the 12pt press promptly; a held finger owns quote selection instead.
            target.panGestureRecognizer.require(toFail: press)
        }
        func detach() { scroll?.removeGestureRecognizer(press); scroll = nil }
        private func point() -> CGPoint {
            guard let scroll else { return .zero }
            let value = press.location(in: scroll)
            return CGPoint(x: value.x - scroll.bounds.minX, y: value.y - scroll.bounds.minY + input.reservedHeight)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { input.canBegin(point()) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        @objc private func handle() {
            switch press.state {
            case .began: input.began(point())
            case .changed: input.changed(point())
            case .ended: input.ended(true)
            case .cancelled, .failed: input.ended(false)
            default: break
            }
        }
    }
}
#endif
