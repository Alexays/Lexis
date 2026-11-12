import AVFoundation
import SwiftUI
import UIKit

/// The view the film is drawn in: an `AVSampleBufferDisplayLayer` filling
/// it, and the bridge that feeds the layer. Built once per player screen
/// and kept by the screen's model, so SwiftUI redraws around it without
/// ever rebuilding the pipeline.
final class PlayerHostView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var bridge: LexisPlayerBridge!

    override init(frame: CGRect) {
        super.init(frame: frame)
        // No background of its own: the screen already draws black under
        // this view, and a second full-screen layer is composited for nothing.
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        layer.addSublayer(displayLayer)
        bridge = LexisPlayerBridge(layer: displayLayer, hostView: self)
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    // The layer is not autoresized with the view.
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
}

struct PlayerHost: UIViewRepresentable {
    let host: PlayerHostView

    func makeUIView(context: Context) -> PlayerHostView { host }
    func updateUIView(_ view: PlayerHostView, context: Context) {}
}
