import Combine
import LexisPlayer
import SwiftUI

struct ContentView: View {
    @State private var model = PlayerModel()
    /// The readout leaves the screen after a few seconds: a video with
    /// nothing drawn over it is the case the renderer's optimized count
    /// measures.
    @State private var ticks = 0

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayerSurface(model: model)
                .ignoresSafeArea()

            if ticks < 10 {
            VStack(alignment: .leading, spacing: 8) {
                Text("FFmpeg \(FFmpegBuild.version)")
                Text("status \(model.status)")
                Text("packets \(model.stats.packetsRead)")
                Text("displayed \(model.stats.framesDisplayed)")
                Text("dropped \(model.stats.framesDropped)")
                Text("rebuffers \(model.stats.rebufferCount)")
                Text("optimized \(model.renderer.optimized) of \(model.renderer.displayed)")
            }
            .font(.system(size: 24, design: .monospaced))
            .foregroundStyle(.white)
            .padding(32)
            .background(.black.opacity(0.5))
            .padding(48)
            }
        }
        .onReceive(ticker) { _ in
            ticks += 1
            model.refreshStats()
        }
    }
}
