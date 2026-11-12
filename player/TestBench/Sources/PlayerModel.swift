import AVFoundation
import Foundation
import LexisPlayer
import LexisTestSupport
import Observation
import QuartzCore

/// Owns the player for as long as the bench runs. Views only read it: the
/// pipeline is never created or driven from inside a view update.
@MainActor
@Observable
final class PlayerModel {
    private(set) var status = "idle"
    private(set) var stats = PlaybackStats()
    /// What the renderer itself counts, logged each refresh: the optimized
    /// figure says whether the display's video plane took the frames.
    private(set) var renderer = (displayed: 0, dropped: 0, optimized: 0)

    @ObservationIgnored private var player: LexisPlayer?
    @ObservationIgnored private var sink: DisplayLayerSink?

    /// Called once the display layer exists, from outside the view update.
    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard player == nil else { return }
        if ProcessInfo.processInfo.arguments.contains("--native") {
            attachNative(to: layer)
            return
        }
        let sink = DisplayLayerSink(layer: layer)
        let player = LexisPlayer(sink: sink)
        self.player = player
        self.sink = sink
        Task { @MainActor [weak self] in
            for await event in player.events {
                self?.status = String(describing: event)
            }
        }
        status = "preparing"
        // Authoring the clip encodes a few hundred frames and open() parses the
        // container: on the main thread that is seconds of frozen UI before the
        // first frame.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try sampleURL()
                try player.open(url: url)
                player.play()
            } catch {
                let message = "failed \(error)"
                guard let self else { return }
                await MainActor.run { self.status = message }
            }
        }
    }

    @ObservationIgnored private var nativeSynchronizer: AVSampleBufferRenderSynchronizer?
    @ObservationIgnored private var nativeRenderer: AVSampleBufferVideoRenderer?
    @ObservationIgnored private var nativeReader: AVAssetReader?

    @ObservationIgnored private var nativeReceiver: AVSampleBufferVideoRenderer.Receiver?
    @ObservationIgnored private var nativeAudio: AVSampleBufferAudioRenderer?
    @ObservationIgnored private var nativeLink: CADisplayLink?
    @ObservationIgnored private var nativeOverlay: CALayer?

    /// Control for the optimized count: the same layer fed straight from an
    /// AVAssetReader, with each piece of the pipeline's setup added back by a
    /// launch flag.
    private func attachNative(to layer: AVSampleBufferDisplayLayer) {
        let flags = ProcessInfo.processInfo.arguments
        status = "native " + flags.filter { $0.hasPrefix("--") }.joined(separator: " ")
        let renderer = layer.sampleBufferRenderer
        let synchronizer = AVSampleBufferRenderSynchronizer()
        if flags.contains("--nodelay") {
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        }
        let receiver: AVSampleBufferVideoRenderer.Receiver?
        if flags.contains("--receiver") {
            receiver = synchronizer.sampleBufferReceiver(adding: renderer)
        } else {
            synchronizer.addRenderer(renderer)
            receiver = nil
        }
        if flags.contains("--audio") {
            let audio = AVSampleBufferAudioRenderer()
            synchronizer.addRenderer(audio)
            nativeAudio = audio
        }
        if flags.contains("--overlay") {
            let overlay = CALayer()
            overlay.frame = layer.bounds
            layer.superlayer?.insertSublayer(overlay, above: layer)
            nativeOverlay = overlay
        }
        if flags.contains("--link") {
            let link = CADisplayLink(target: self, selector: #selector(nativeTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 4, preferred: 4)
            link.add(to: .main, forMode: .common)
            nativeLink = link
        }
        let stripDuration = flags.contains("--noduration")
        nativeRenderer = renderer
        nativeSynchronizer = synchronizer
        nativeReceiver = receiver
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try sampleURL()
                let asset = AVURLAsset(url: url)
                let track = try await asset.loadTracks(withMediaType: .video)[0]
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output)
                reader.startReading()
                await MainActor.run { self?.nativeReader = reader }
                func next() -> CMSampleBuffer? {
                    guard let sample = output.copyNextSampleBuffer() else { return nil }
                    guard stripDuration else { return sample }
                    var timing = CMSampleTimingInfo()
                    CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
                    timing.duration = .invalid
                    var copy: CMSampleBuffer?
                    CMSampleBufferCreateCopyWithNewTiming(
                        allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                        sampleTimingArray: &timing, sampleBufferOut: &copy)
                    return copy ?? sample
                }
                if let receiver {
                    Task.detached {
                        while let sample = next() {
                            _ = try? await receiver.enqueue(CMReadySampleBuffer(unsafeBuffer: sample))
                        }
                    }
                } else {
                    let queue = DispatchQueue(label: "bench.native")
                    renderer.requestMediaDataWhenReady(on: queue) {
                        while renderer.isReadyForMoreMediaData {
                            guard let sample = next() else {
                                renderer.stopRequestingMediaData()
                                return
                            }
                            renderer.enqueue(sample)
                        }
                    }
                }
                synchronizer.setRate(1, time: .zero)
                traceLine("[bench.render] native start")
            } catch {
                let message = "failed \(error)"
                guard let self else { return }
                await MainActor.run { self.status = message }
            }
        }
    }

    @objc private func nativeTick(_ link: CADisplayLink) {}

    /// `--seek-at <s> --seek-to <s>`: one seek, at the given tick of the
    /// clock, for measuring what a landing costs on each path.
    @ObservationIgnored private var seekDone = false

    func refreshStats() {
        if let player {
            stats = player.stats
            let arguments = ProcessInfo.processInfo.arguments
            if !seekDone, let at = arguments.firstIndex(of: "--seek-at"), at + 1 < arguments.count,
               let after = Double(arguments[at + 1]), stats.position >= after,
               let to = arguments.firstIndex(of: "--seek-to"), to + 1 < arguments.count,
               let target = Double(arguments[to + 1]) {
                seekDone = true
                traceLine(String(format: "[bench.render] seeking from %.1f to %.1f", stats.position, target))
                player.seek(to: target)
            }
        }
        guard let nativeRenderer else {
            sink?.loadRendererMetrics { [weak self] metrics in
                guard let metrics else { return }
                Task { @MainActor in
                    self?.renderer = (metrics.displayed, metrics.dropped, metrics.optimized)
                }
                traceLine(String(
                    format: "[bench.render] displayed %d, dropped %d, optimized %d",
                    metrics.displayed, metrics.dropped, metrics.optimized))
            }
            return
        }
        nativeRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
            guard let metrics else { return }
            let read = (metrics.totalNumberOfFrames, metrics.numberOfDroppedFrames,
                        metrics.numberOfFramesDisplayedUsingOptimizedCompositing)
            Task { @MainActor in self?.renderer = read }
            traceLine(String(
                format: "[bench.render] native displayed %d, dropped %d, optimized %d",
                read.0, read.1, read.2))
        }
    }
}

/// Plays a file dropped into the app's Caches directory when there is one, and
/// otherwise a clip the app authors on first launch, so the bench ships no
/// media of its own. Slow enough that it must stay off the main thread.
private func sampleURL() throws -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let dropped = caches.appendingPathComponent("sample.mp4")
    // `--fetch <url>` replaces the dropped file with one served over the
    // network: nothing else gets a file into the container on a device.
    let arguments = ProcessInfo.processInfo.arguments
    if let at = arguments.firstIndex(of: "--fetch"), at + 1 < arguments.count,
       let remote = URL(string: arguments[at + 1]) {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = URLSession.shared.downloadTask(with: remote) { location, _, error in
            defer { done.signal() }
            guard let location else { failure = error; return }
            try? FileManager.default.removeItem(at: dropped)
            do { try FileManager.default.moveItem(at: location, to: dropped) } catch { failure = error }
        }
        task.resume()
        done.wait()
        if let failure { throw failure }
        traceLine("[bench.render] fetched \(remote.lastPathComponent)")
        return dropped
    }
    if FileManager.default.fileExists(atPath: dropped.path) {
        return dropped
    }
    let generated = caches.appendingPathComponent("testbench-fixture-2160.mp4")
    if FileManager.default.fileExists(atPath: generated.path) {
        return generated
    }
    return try makeVideoFixture(
        directory: caches, name: "testbench-fixture-2160.mp4", codec: .hevc,
        width: 3840, height: 2160, frameCount: 240, fps: 24
    )
}
