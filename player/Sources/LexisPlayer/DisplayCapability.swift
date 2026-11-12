import AVFoundation
import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// What the screen can show, and therefore what has to be done to the picture
/// before it is enqueued.
public struct DisplayCapability: Sendable, Equatable {
    /// How far above SDR white the display goes. 1.0 is an SDR screen, which
    /// is what every simulator reports.
    public let headroom: Float

    /// Whether this device and the screen it is attached to can show Dolby
    /// Vision between them. Its own question, not a headroom threshold: a
    /// display reports plenty of headroom without doing Dolby Vision, and the
    /// two must not be read off each other.
    public let supportsDolbyVision: Bool

    /// Whether the display attached can show high dynamic range at all.
    ///
    /// A different question from the headroom beside it, and the one that
    /// actually decides the path. The headroom answers for the mode the
    /// screen is in right now: a projector that supports HDR but is emitting
    /// SDR - which is every screen at the moment a film opens, since the mode
    /// is only asked for once the film has been read - reports none. This
    /// answers for the screen rather than for its mode, so it is true before
    /// the HDMI has renegotiated and stays true across it.
    public let eligibleForHDR: Bool

    /// The screen's height in pixels, in the orientation a film plays in.
    /// 0 where nothing asked (every capability a test builds by hand): a
    /// screen of unknown size upscales nothing.
    public let pixelHeight: Int

    /// Defaults to no Dolby Vision, which is what every screen was assumed to
    /// be before this and what every platform but tvOS still has no way to say.
    public init(
        headroom: Float, supportsDolbyVision: Bool = false, pixelHeight: Int = 0,
        eligibleForHDR: Bool = false
    ) {
        self.headroom = headroom
        self.supportsDolbyVision = supportsDolbyVision
        self.pixelHeight = pixelHeight
        self.eligibleForHDR = eligibleForHDR
    }

    /// Either fact, and on tvOS only the second one ever answers.
    ///
    /// `potentialEDRHeadroom` was the whole of this, on the reasoning that it
    /// describes what a screen could do rather than what it is doing. Measured
    /// on an Apple TV 4K driving a Dolby Vision projector, with the box pinned
    /// to Dolby Vision output, it reads 1.00 - a display already in an HDR
    /// mode, reporting no range at all. It answers for the UI compositor's
    /// extended range, which tvOS does not offer, and never for the HDMI
    /// signal. Every high dynamic range film on that box was therefore mapped
    /// down to SDR and handed to a screen in Dolby Vision, which is what a
    /// washed-out picture with grey blacks is.
    ///
    /// The eligibility answers the question that was being asked all along:
    /// whether an HDR display is attached. It is kept alongside the headroom
    /// rather than replacing it because the headroom still answers on the
    /// platforms where it works, and carries how MUCH range there is.
    ///
    /// What this gives up: a viewer with Match Content off and the box pinned
    /// to SDR output has an eligible display that will not be asked for the
    /// mode (see the bridge's `applyDisplayCriteria`), and their picture is
    /// handed over for the platform's own compositor to convert rather than
    /// mapped by the curve here. That is one configuration losing a better
    /// conversion; the reading it replaces was wrong for every other one.
    public var isHighDynamicRange: Bool { headroom > 1.05 || eligibleForHDR }

    /// The peak the curve maps onto, as a PQ code: SDR white is 100 nits by
    /// convention and the headroom multiplies it.
    public var targetMaxPQ: Float {
        pqInverseEOTF(peakNits / 10000)
    }

    /// What the screen is taken to peak at, in cd/m2.
    ///
    /// The headroom decides it where there is one. Where the display is known
    /// to be HDR and reports none - every tvOS screen, see above - 600 stands
    /// in: an assumption, and the figure most consumer HDR panels and
    /// projectors actually reach rather than the 1000 or 4000 a grade was
    /// mastered against. It is only ever read on the mapped path, which an
    /// eligible display takes for one reason alone: a Dolby Vision stream it
    /// cannot be handed. Mapping that to 100 nits - what this returned before,
    /// with no headroom to go on - would land an HDR grade at SDR white.
    var peakNits: Double {
        let stated = Double(headroom) * 100
        let floor = eligibleForHDR ? 600.0 : 100.0
        return min(max(stated, floor), 10000)
    }

    /// What a picture mapped for this screen is stored as.
    ///
    /// Half floats are the only format here that can hold light above SDR
    /// white, and a screen with headroom is the only destination that has
    /// somewhere to put it. Without headroom the curve lands everything at or
    /// below white, and the picture goes into eight bits behind the BT.2020
    /// space's transfer function instead: the same light, in half the bytes.
    public var toneMapPixelFormat: OSType {
        isHighDynamicRange ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
    }

    /// The screen the player is on. Read at each open, and again by
    /// `LexisPlayer.displayConfigurationChanged` when the platform says the
    /// screens moved.
    ///
    /// Both screen APIs are main actor state and `open` is called from
    /// whatever thread the host uses. Off main this answers with what main
    /// last read, and blocks on main only when nothing has been read since
    /// the screens last moved: a host reads it on main before queueing an
    /// open, because main at that moment is busy mounting the interface.
    /// Call it before taking any lock the main thread can be waiting on.
    @Sendable
    public static func current() -> DisplayCapability {
        guard Thread.isMainThread else {
            cacheLock.lock()
            let known = cached
            cacheLock.unlock()
            return known ?? DispatchQueue.main.sync { current() }
        }
        let capability = MainActor.assumeIsolated { screen() }
        cacheLock.lock()
        cached = capability
        cacheLock.unlock()
        return capability
    }

    /// What main last read, for `current` to answer with off main. Under
    /// `cacheLock`.
    private static let cacheLock = NSLock()
    private static var cached: DisplayCapability?

    /// Forgets what main last read: the screens moved, so the next reading
    /// off main has to come from main again.
    public static func screensChanged() {
        cacheLock.lock()
        cached = nil
        cacheLock.unlock()
    }

    /// The potential headroom on both platforms, never the current one: the
    /// current headroom answers for what is on screen now, and at open no
    /// layer is asking for extended range yet, so a capable display reports
    /// 1.0 and every stream would take the mapped path forever. It also
    /// drifts with brightness and power, which the path a file takes must not.
    @MainActor
    private static func screen() -> DisplayCapability {
        #if canImport(AppKit)
        // The key window's screen, which on a two-display Mac is not
        // necessarily the one the picture is on, and nil when no window has
        // focus: both mean "assume SDR" here.
        let screen = NSScreen.main
        return DisplayCapability(
            headroom: Float(
                screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1),
            pixelHeight: screen.map { Int($0.frame.height * $0.backingScaleFactor) } ?? 0
        )
        #elseif canImport(UIKit)
        #if os(tvOS)
        // The only thing the platform will say about the screen's Dolby
        // Vision: it answers for the display that is attached and for this
        // device's own ability to drive it, which is both halves of the
        // question.
        //
        // Deprecated since tvOS 26, and there is nothing to move to. Apple
        // names `eligibleForHDRPlayback` as the replacement; it is a Bool
        // about high dynamic range in general and cannot tell Dolby Vision
        // from HDR10, so taking it would answer a different question. The
        // whole SDK offers no other: `AVPlayerHDRMode` is the last symbol on
        // the platform that names Dolby Vision at all, and it is deprecated
        // with the property that returns it.
        //
        // So this stays until it is removed, at which point it stops
        // compiling - loud, and the right kind of failure. What it must not
        // do meanwhile is go quiet: a display that stops being reported takes
        // every Dolby Vision film down the tone mapped path, and that reads
        // as a badly graded film rather than as a broken capability. It is
        // reported in the player's stats for that reason, beside the headroom
        // that turned out to answer nothing on this platform.
        let dolbyVision = AVPlayer.availableHDRModes.contains(.dolbyVision)
        // What the platform says about the screen rather than about the mode
        // it is in: true for a display that can show HDR, whatever it happens
        // to be emitting while this is read.
        let eligible = AVPlayer.eligibleForHDRPlayback
        #else
        let dolbyVision = false
        let eligible = false
        #endif
        // The screen of the scene the app is showing on. None before a scene
        // is connected, which is the SDR screen of unknown size every test
        // capability assumes. nativeBounds is portrait-oriented on iPhone; a
        // film plays in landscape, so its height there is the smaller side.
        // On tvOS the two readings agree.
        let screen = UIApplication.shared.connectedScenes.lazy
            .compactMap { $0 as? UIWindowScene }.first?.screen
        let native = screen?.nativeBounds ?? .zero
        return DisplayCapability(
            headroom: Float(screen?.potentialEDRHeadroom ?? 1), supportsDolbyVision: dolbyVision,
            pixelHeight: Int(min(native.width, native.height)), eligibleForHDR: eligible
        )
        #else
        return DisplayCapability(headroom: 1)
        #endif
    }
}

public enum VideoPath: Sendable, Equatable {
    /// Packets go to the display layer, which decodes them. What every stream
    /// did before this plan.
    case passthrough
    /// Decoded here, mapped by the kernel, enqueued as pictures.
    case toneMapped
    /// Decoded here, made bigger by the upscaler, enqueued as pictures:
    /// the path a small SDR film takes onto a screen with far more pixels.
    case upscaled
    /// Decoded here, enqueued as the pictures the decoder made: the path an
    /// HDR film takes on tvOS, where the display layer's own decoding drops
    /// frames on a deep B pyramid.
    case decoded
    /// Decoded here and built up a field at a time, the pictures otherwise
    /// the decoder's own: the faithful rendering of an interlaced SDR film,
    /// which a display layer decoding for itself would weave into half the
    /// pictures a second the film was shot at.
    case deinterlaced
}

/// What the upscaled path renders at for this stream on this screen, or nil
/// where nothing is to be gained: a screen of unknown size, or one the
/// picture already nearly fills. Twice the film, the one factor the scaler's
/// filters are learned for, or where that falls short of a 16:9 screen, as a
/// 720p or SD film's does, the film fitted to the screen, its pixels' shape
/// kept: the scaler finishes the factor past 2x by a sharper filter than the
/// compositor's bilinear. Not past 30 pictures a second, where that 4K pass
/// would not fit the frame; the compositor covers the rest there.
public func upscaleTarget(
    for stream: MediaStream, capability: DisplayCapability
) -> (width: Int32, height: Int32)? {
    guard stream.width > 0, stream.height > 0,
        capability.pixelHeight >= Int(stream.height) * 3 / 2
    else { return nil }
    let screen = (width: Double(capability.pixelHeight) * 16 / 9, height: Double(capability.pixelHeight))
    let pixelAspect = stream.pixelAspectNum > 0 && stream.pixelAspectDen > 0
        ? Double(stream.pixelAspectNum) / Double(stream.pixelAspectDen) : 1
    let fit = min(screen.height / Double(stream.height), screen.width / (Double(stream.width) * pixelAspect))
    guard fit > 2, (stream.outputFrameRate ?? 24) <= 30 else { return (stream.width * 2, stream.height * 2) }
    // even, as a 4:2:0 picture's planes are
    return (
        Int32((Double(stream.width) * fit / 2).rounded()) * 2, Int32((Double(stream.height) * fit / 2).rounded()) * 2
    )
}

/// The 'dvh1' description a profile 5, 7 or 8 stream can go to the display
/// layer with, or nil when it cannot: profile 5 then takes the mapped path,
/// and the others go as the HDR10, SDR or HLG their base layer is. Profile 7
/// is described as the 8.1 the engine turns each of its access units into,
/// its enhancement layer left behind.
///
/// The session is opened and thrown away rather than reasoned about, because
/// nothing downstream will say: an `AVSampleBufferDisplayLayer` handed a
/// format description it cannot decode reports `.rendering` with no error,
/// measured, and so does one handed a codec type that does not exist. This is
/// the only place the answer can be had, and a device that says no falls back
/// to exactly what it did before.
public func dolbyVisionPassthroughFormat(
    for stream: MediaStream, capability: DisplayCapability
) -> CMVideoFormatDescription? {
    guard capability.supportsDolbyVision, let dolbyVision = stream.dolbyVision, dolbyVision.hasRPU else {
        return nil
    }
    let handedOver: DolbyVisionConfiguration
    switch dolbyVision.profile {
    case 5, 8 where !dolbyVision.hasEnhancementLayer: handedOver = dolbyVision
    case 7 where dolbyVision.compatibility == 6 && dolbyVision.hasBaseLayer:
        handedOver = dolbyVisionEightOne(from: dolbyVision)
    default: return nil
    }
    guard let format = try? makeDolbyVisionFormatDescription(for: stream, configuration: handedOver) else {
        return nil
    }
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
        imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session
    )
    guard status == noErr, let session else { return nil }
    VTDecompressionSessionInvalidate(session)
    return format
}

/// Which path a stream takes on this screen. `dolbyVisionPassthrough` is
/// what `dolbyVisionPassthroughFormat` answered for this stream and screen,
/// asked once by the caller that also needs the description it returns.
/// `upscalingAllowed` is the player's own switch; false leaves every answer
/// exactly what it was before the upscaled path existed. `decodesHDRHere`
/// is the platform's: on tvOS a display layer decoding an HDR stream for
/// itself throws pictures away wherever the stream reorders through a deep
/// B pyramid, AVFoundation's own reader feeding it included, and a session
/// of our own does not.
public func videoPath(
    for stream: MediaStream, capability: DisplayCapability, dolbyVisionPassthrough: Bool = false,
    upscalingAllowed: Bool = false, decodesHDRHere: Bool = platformDecodesHDRHere
) -> VideoPath {
    let isHDR = isPerceptualQuantizer(stream.colorTransfer) || isHybridLogGamma(stream.colorTransfer)
    // A codec this device cannot decode in hardware, AV1 on an A15, decodes
    // in software here, and goes to the display layer as it is.
    let software = hardwareDecodes(stream) == false
    // The display layer taking the stream as Dolby Vision is the whole
    // picture, RPU included: nothing here could improve on it. The viewer
    // choosing HDR10 is what turns it off, for a screen smoother in HDR10.
    if dolbyVisionPassthrough { return .passthrough }
    // Every other HDR stream is decoded here, a Dolby Vision base layer as
    // the HDR10 it also is: a film that never stutters is what it buys. A
    // profile 5 base layer is no picture without the record, and is mapped.
    if decodesHDRHere, isHDR, capability.isHighDynamicRange,
        stream.dolbyVision?.baseLayerIsDisplayable ?? true, hardwareDecodes(stream) == true
    {
        return .decoded
    }
    // A profile 5 base layer is IPT-PQ-c2 and is not a picture: handing it to
    // a display that cannot do Dolby Vision paints it in the wrong hues, so it
    // is mapped here.
    if let dolbyVision = stream.dolbyVision, !dolbyVision.baseLayerIsDisplayable {
        return .toneMapped
    }
    // The two transfers the kernel decodes, and only where the screen cannot
    // show them as they are: SDR and every other transfer go to the display
    // layer untouched - unless the picture is small enough on this screen
    // for the upscaled path to be worth building.
    guard isHDR else {
        // every other path is built on a VideoToolbox session of its own
        if software { return .passthrough }
        if upscalingAllowed, upscaleTarget(for: stream, capability: capability) != nil {
            return .upscaled
        }
        return stream.isInterlaced ? .deinterlaced : .passthrough
    }
    return capability.isHighDynamicRange || software ? .passthrough : .toneMapped
}

#if os(tvOS)
public let platformDecodesHDRHere = true
#else
public let platformDecodesHDRHere = false
#endif
