import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// Draws one cue over the video: text stacked above the bottom of the picture,
/// or the bitmaps a graphic subtitle carries. It owns a layer and nothing else;
/// when to show what is the sink's business.
public final class SubtitleOverlay {
    /// A share of the picture height. Every TV subtitle is about this size.
    private static let fontScale = 0.045
    /// How far above the bottom of the picture the last line sits.
    private static let bottomMargin = 0.06
    private static let lineSpacing = 1.25

    public let layer = CALayer()
    /// Kept and reused: a cue every few seconds must not rebuild a layer tree.
    private var textLayers: [CATextLayer] = []
    private var imageLayers: [CALayer] = []
    /// The libass path's own layer, kept apart from the two above: the styled
    /// path and the queued-cue path are driven by two observers on two queues
    /// and must never clear each other's work.
    private lazy var styledLayer: CALayer = {
        let sublayer = CALayer()
        sublayer.contentsGravity = .resize
        sublayer.magnificationFilter = .linear
        sublayer.isHidden = true
        layer.addSublayer(sublayer)
        return sublayer
    }()
    /// How much room something drawn over the picture is taking at the bottom
    /// of the layer, in points: what a cue is lifted clear of. Anything
    /// already above that band does not move, so a sign at the top of the
    /// frame stays where its author put it.
    public var lift: CGFloat = 0 {
        didSet {
            guard lift != oldValue else { return }
            // the cue on screen was placed against the old band, and there may
            // not be another one for a while: it moves, it is not drawn again
            if let shown {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                draw(
                    shown.images,
                    canvas: CGSize(width: shown.canvasWidth, height: shown.canvasHeight),
                    in: shownBounds, filling: false
                )
                draw(shown.lines, in: shownBounds, filling: false)
                CATransaction.commit()
            }
            placeStyled()
        }
    }
    /// The white a cue is drawn at, 1 the layer's own. On an HDR screen the
    /// system's graphics white sits well above the hundred or so nits a
    /// subtitle is mastered at, and a white line that bright glares over a
    /// dark scene. Taken by the next cue drawn.
    public var white: CGFloat = 1 {
        didSet {
            for text in textLayers { text.foregroundColor = CGColor(gray: white, alpha: 1) }
        }
    }
    /// Code values, which the layer's gamma takes to about half the light.
    public static let hdrWhite: CGFloat = 0.75
    /// The same once the sun is down, a room then being dark: about three
    /// fifths of that light, which still reads and no longer glares under a
    /// night scene.
    public static let nightWhite: CGFloat = 0.6
    private var shown: SubtitleCue?
    private var shownBounds = CGRect.zero
    /// What the styled layout was computed from, so a resize can re-apply it
    /// without a bitmap: the styled caller only calls when libass changed one.
    private var styledImage: SubtitleImage?
    private var styledCanvas = CGSize.zero
    /// The pixel size the styled bitmap was rasterized at, which is the video's
    /// unless libass was told a screen-resolution frame size.
    private var styledFrameCanvas = CGSize.zero
    private var styledBounds = CGRect.zero

    public init() {
        layer.isOpaque = false
        // above the picture, whatever order the host adds its own sublayers in
        layer.zPosition = 1
        #if os(macOS)
        // AppKit gives a hosted layer its origin at the bottom left; everything
        // below is written for the top-left one UIKit gives on tvOS.
        layer.isGeometryFlipped = true
        #endif
    }

    /// Where a canvas of `canvas` lands inside `bounds` under aspect fit, which
    /// is where the video lands too: the display layer letterboxes the picture
    /// the same way, and a bitmap subtitle is positioned against the picture
    /// rather than against the screen.
    public static func fit(canvas: CGSize, in bounds: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Puts `cue` on screen inside `bounds`, or clears it when nil. The main
    /// thread only: this is a layer tree.
    public func show(_ cue: SubtitleCue?, in bounds: CGRect) {
        guard cue != shown || bounds != shownBounds else { return }
        shown = cue
        shownBounds = bounds
        // no implicit animation: a fade between two lines of dialogue reads as
        // a smear, and every cue would pay for it
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.frame = bounds
        // This tick is unconditional, the styled one is not, so a resize
        // reaches the styled slot here or not at all.
        if bounds != styledBounds, styledImage != nil {
            styledBounds = bounds
            placeStyled()
        }
        for sublayer in textLayers { sublayer.isHidden = true }
        for sublayer in imageLayers { sublayer.isHidden = true }
        guard let cue else { return }
        draw(
            cue.images,
            canvas: CGSize(width: cue.canvasWidth, height: cue.canvasHeight),
            in: bounds, filling: true
        )
        draw(cue.lines, in: bounds, filling: true)
    }

    /// Puts one styled bitmap on screen inside `bounds`, or clears it when nil.
    /// `canvas` is the video's size - what positions are authored against -
    /// and `frameCanvas` the pixel size the bitmap was rasterized at, which
    /// libass scales its output to. When the two differ the bitmap arrives at
    /// screen resolution and is placed by the frame ratio, so glyphs are never
    /// upscaled by this layer. The main thread only: this is a layer tree.
    /// Gate the calls on `AssRenderer.generation`: a new bitmap builds a CGImage
    /// and re-uploads megabytes of layer contents, and only the same bitmap
    /// moved elsewhere is placed without one. A resize needs no call of its own.
    public func showStyled(
        _ image: SubtitleImage?, canvas: CGSize, frameCanvas: CGSize, in bounds: CGRect
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.frame = bounds
        // the same bitmap moved elsewhere keeps the contents it already has
        let kept = image.map { $0.bitmap == styledImage?.bitmap } ?? false
        // the renderer already blended its glyphs at `white`
        let drawn = kept ? nil : image?.makeImage()
        guard let image, canvas.width > 0, kept || drawn != nil else {
            styledImage = nil
            // nothing caches this, and it is up to six megabytes to hold on to
            styledLayer.contents = nil
            styledLayer.isHidden = true
            return
        }
        styledImage = image
        styledCanvas = canvas
        styledFrameCanvas = frameCanvas.width > 0 ? frameCanvas : canvas
        styledBounds = bounds
        if let drawn { styledLayer.contents = drawn }
        placeStyled()
        styledLayer.isHidden = false
    }

    /// Places the styled bitmap against the picture, from what the last call
    /// gave: the same arithmetic a PGS rect gets, so the two paths agree.
    private func placeStyled() {
        guard let image = styledImage, styledCanvas.width > 0 else { return }
        let picture = SubtitleOverlay.fit(canvas: styledCanvas, in: styledBounds)
        let scale = picture.width / styledFrameCanvas.width
        styledLayer.frame = lifted(
            CGRect(
                x: picture.minX + CGFloat(image.x) * scale,
                y: picture.minY + CGFloat(image.y) * scale,
                width: CGFloat(image.width) * scale,
                height: CGFloat(image.height) * scale
            ),
            in: styledBounds
        )
    }

    /// `frame` moved up by however much of it falls inside the band the host
    /// is drawing in, and left alone when none of it does: a line of dialogue
    /// clears the transport overlay, a sign at the top of the picture does not
    /// move at all.
    private func lifted(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        let floorY = bounds.height - lift
        guard lift > 0, frame.maxY > floorY else { return frame }
        return frame.offsetBy(dx: 0, dy: floorY - frame.maxY)
    }

    /// `filling` false only moves layers already showing these lines: the
    /// text is not set again, which would redraw and re-rasterize it.
    private func draw(_ lines: [String], in bounds: CGRect, filling: Bool) {
        guard !lines.isEmpty, bounds.height > 0 else { return }
        let size = bounds.height * SubtitleOverlay.fontScale
        let height = size * SubtitleOverlay.lineSpacing
        var bottom = min(
            bounds.height - bounds.height * SubtitleOverlay.bottomMargin,
            bounds.height - lift
        )
        let font = filling ? CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil) : nil
        // from the last line up, so the stack ends at the same margin however
        // many lines there are
        for (order, line) in lines.enumerated().reversed() {
            bottom -= height
            let text = textLayer(order)
            text.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: height)
            guard let font else { continue }
            text.font = font
            text.fontSize = size
            text.string = line
            text.isHidden = false
        }
    }

    /// `filling` false only moves the layers already showing these images,
    /// without building their bitmaps again.
    private func draw(
        _ images: [SubtitleImage], canvas: CGSize, in bounds: CGRect, filling: Bool
    ) {
        guard !images.isEmpty, canvas.width > 0 else { return }
        let picture = SubtitleOverlay.fit(canvas: canvas, in: bounds)
        let scale = picture.width / canvas.width
        for (order, image) in images.enumerated() {
            let sublayer: CALayer
            if filling {
                guard let drawn = image.makeImage(white: white) else { continue }
                sublayer = imageLayer(order)
                sublayer.contents = drawn
            } else {
                // a bitmap that failed to build was never shown
                guard order < imageLayers.count, !imageLayers[order].isHidden else { continue }
                sublayer = imageLayers[order]
            }
            sublayer.frame = lifted(
                CGRect(
                    x: picture.minX + CGFloat(image.x) * scale,
                    y: picture.minY + CGFloat(image.y) * scale,
                    width: CGFloat(image.width) * scale,
                    height: CGFloat(image.height) * scale
                ),
                in: bounds
            )
            sublayer.isHidden = false
        }
    }

    /// Grows the cache rather than indexing into it: the lines are drawn from
    /// the last one up, so the first layer asked for is not the first one.
    private func textLayer(_ order: Int) -> CATextLayer {
        while textLayers.count <= order {
            let text = CATextLayer()
            text.alignmentMode = .center
            text.truncationMode = .none
            text.isWrapped = false
            text.foregroundColor = CGColor(gray: white, alpha: 1)
            // what keeps white text readable over a white shirt
            text.shadowColor = CGColor(gray: 0, alpha: 1)
            text.shadowOpacity = 1
            text.shadowRadius = 3
            text.shadowOffset = .zero
            text.contentsScale = layer.contentsScale
            // A shadow with no path is an offscreen pass on every composite;
            // the text changes once a cue, so its shadowed raster is kept.
            text.shouldRasterize = true
            text.rasterizationScale = layer.contentsScale
            layer.addSublayer(text)
            textLayers.append(text)
        }
        return textLayers[order]
    }

    private func imageLayer(_ order: Int) -> CALayer {
        while imageLayers.count <= order {
            let sublayer = CALayer()
            sublayer.contentsGravity = .resize
            sublayer.magnificationFilter = .linear
            layer.addSublayer(sublayer)
            imageLayers.append(sublayer)
        }
        return imageLayers[order]
    }
}
