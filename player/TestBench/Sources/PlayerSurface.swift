import AVFoundation
import SwiftUI
import UIKit

final class SampleBufferView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}

struct PlayerSurface: UIViewRepresentable {
    let model: PlayerModel

    func makeUIView(context: Context) -> SampleBufferView {
        let view = SampleBufferView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        // Deferred on purpose: attaching writes model state, and that must not
        // happen while SwiftUI is building this view.
        Task { @MainActor in
            model.attach(to: view.displayLayer)
        }
        return view
    }

    func updateUIView(_ view: SampleBufferView, context: Context) {}
}
