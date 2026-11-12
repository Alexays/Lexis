import SwiftUI
import UIKit

/// The Siri Remote's touch surface and its held left and right, listened
/// to from the window: presses and touches go to whichever view holds
/// focus, and a recogniser on the window sees every one of them.
struct RemoteGestures: UIViewRepresentable {
    let model: PlayerModel

    func makeUIView(context: Context) -> RemoteSurfaceView { RemoteSurfaceView(model: model) }
    func updateUIView(_ view: RemoteSurfaceView, context: Context) {}
}

final class RemoteSurfaceView: UIView, UIGestureRecognizerDelegate {
    private let model: PlayerModel
    private var recognizers: [UIGestureRecognizer] = []

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for recognizer in recognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizers = []
        guard let window else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        let left = UILongPressGestureRecognizer(target: self, action: #selector(heldLeft))
        left.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        let right = UILongPressGestureRecognizer(target: self, action: #selector(heldRight))
        right.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        recognizers = [pan, left, right]
        for recognizer in recognizers {
            // The focus engine keeps reading the same touches and presses.
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let phase: PlayerModel.PanPhase
        switch recognizer.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended, .cancelled, .failed: phase = .ended
        default: return
        }
        let x = recognizer.translation(in: recognizer.view).x
        MainActor.assumeIsolated { model.pan(phase, x: x) }
    }

    @objc private func heldLeft(_ recognizer: UILongPressGestureRecognizer) { held(recognizer, back: true) }
    @objc private func heldRight(_ recognizer: UILongPressGestureRecognizer) { held(recognizer, back: false) }

    private func held(_ recognizer: UILongPressGestureRecognizer, back: Bool) {
        switch recognizer.state {
        case .began: MainActor.assumeIsolated { model.hold(back: back, began: true) }
        case .ended, .cancelled, .failed: MainActor.assumeIsolated { model.hold(back: back, began: false) }
        default: break
        }
    }
}
