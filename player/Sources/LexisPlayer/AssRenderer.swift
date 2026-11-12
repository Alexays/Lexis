import CLibass
import CoreGraphics
import Foundation

public enum AssRenderError: Error, Equatable {
    case libraryUnavailable
    case rendererUnavailable
    case trackUnavailable
    /// A canvas of nothing: a container with no video stream, or one that does
    /// not say how big its picture is. There is nowhere to put a subtitle.
    case invalidCanvas
    /// Neither the system nor the container had a font, so this track would
    /// draw an empty screen for its whole length. Better said out loud.
    case fontsUnavailable
}

/// Draws an ASS/SSA track the way its author styled it: fonts, colours,
/// outlines, alignment, positioning and animation, through libass.
///
/// libass is not thread-safe and this class owns three of its objects, so
/// **every method must be called on `sharedQueue`** and nothing else may touch
/// them. Every method asserts it.
public final class AssRenderer {
    /// The one queue every libass call in this process happens on, and the only
    /// one any of them may happen on: it is not a parameter because freeing a
    /// renderer while another draws is what `-DHB_NO_MT` forbids, and only a
    /// single queue orders two renderers against each other.
    public static let sharedQueue = DispatchQueue(label: "org.lexis.libass", qos: .userInitiated)
    /// What the images are positioned against: the video's own size, exactly as
    /// for a PGS rect, so the overlay places both the same way.
    public let canvas: CGSize
    /// Bumped whenever a new bitmap was built or the last one was taken back.
    /// The caller compares this instead of comparing pixels, which at 30 Hz and
    /// up to six megabytes a frame is the difference between free and not.
    public private(set) var generation: UInt64 = 0

    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let track: UnsafeMutablePointer<ASS_Track>
    /// What libass drew last, kept so a tick where nothing changed costs one
    /// call and no allocation.
    private var lastImage: SubtitleImage?
    /// Where each image of that list sat, x then y, so a tick where libass
    /// only moved them can tell a shift of the whole bitmap from anything else.
    private var positions: [Int32] = []
    /// The two bitmaps compose alternates between: `drawn` backs the one
    /// published last, and `spare` is drawn into once nothing still holds it.
    private var drawn: PixelBuffer?
    private var spare: PixelBuffer?
    /// The frame size libass is currently rasterizing at: a setFrameSize for
    /// the size already applied must not bump the generation, or every publish
    /// would republish itself once and break the draw-once contract.
    private var appliedFrameSize: CGSize = .zero
    /// The white the glyphs are blended at, as `SubtitleOverlay.white`: scaled
    /// here, once per image, rather than over every pixel of the bitmap after.
    private var whiteScale: UInt32 = 256

    public func setWhite(_ white: CGFloat) {
        dispatchPrecondition(condition: .onQueue(AssRenderer.sharedQueue))
        let scale = UInt32(min(max(white, 0), 1) * 256)
        guard scale != whiteScale else { return }
        whiteScale = scale
        lastImage = nil
        generation &+= 1
    }

    /// `header` is the track's codec extradata, which is the script's
    /// `[Script Info]` and `[V4+ Styles]` sections. `fonts` are whole font
    /// files, normally the container's attachments; anything in there that is
    /// not a font is refused by FreeType rather than by this code.
    public init(
        header: Data, fonts: [Data], canvasWidth: Int, canvasHeight: Int
    ) throws {
        dispatchPrecondition(condition: .onQueue(AssRenderer.sharedQueue))
        canvas = CGSize(width: canvasWidth, height: canvasHeight)
        guard canvasWidth > 0, canvasHeight > 0 else {
            throw AssRenderError.invalidCanvas
        }

        guard let library = ass_library_init() else {
            throw AssRenderError.libraryUnavailable
        }
        // deinit never runs for an init that throws, so every failure below
        // gives back what was allocated above it.
        var kept = false
        defer { if !kept { ass_library_done(library) } }
        // The fonts have to be in the library before the renderer builds its
        // provider; one added later would not be seen.
        for (order, font) in fonts.enumerated() {
            font.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                // libass copies the bytes, so the Data's lifetime ends here
                ass_add_font(
                    library, "attachment-\(order)",
                    base.assumingMemoryBound(to: CChar.self), Int32(raw.count)
                )
            }
        }
        guard let renderer = ass_renderer_init(library) else {
            throw AssRenderError.rendererUnavailable
        }
        defer { if !kept { ass_renderer_done(renderer) } }
        // Both sizes are the video's: the script's own PlayRes is what libass
        // lays out in, and it scales that into this.
        ass_set_frame_size(renderer, Int32(canvasWidth), Int32(canvasHeight))
        ass_set_storage_size(renderer, Int32(canvasWidth), Int32(canvasHeight))
        ass_set_pixel_aspect(renderer, 1.0)
        // Hinting fights smooth scaling, which every positioned or animated
        // script depends on.
        ass_set_hinting(renderer, ASS_HINTING_NONE)
        // CoreText is the only system font provider on this platform, and
        // Helvetica is what catches a script naming a family nobody has.
        ass_set_fonts(
            renderer, nil, "Helvetica",
            Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1
        )
        guard let track = ass_new_track(library) else {
            throw AssRenderError.trackUnavailable
        }
        defer { if !kept { ass_free_track(track) } }
        header.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ass_process_codec_private(
                track, base.assumingMemoryBound(to: CChar.self), Int32(raw.count)
            )
        }

        // One throwaway event, rendered and taken back: a font provider that
        // answers nothing draws nothing, and a track that will never draw
        // should say so at open rather than look like an empty film. It runs on
        // the locals rather than through process(), because self is not built
        // yet and this must be able to throw without leaking the three handles
        // the defers above still hold.
        let probe = #"0,0,Default,,0,0,0,,ABC"#
        probe.withCString { ass_process_chunk(track, $0, Int32(strlen($0)), 0, 1000) }
        let drew = ass_render_frame(renderer, track, 500, nil) != nil
        ass_flush_events(track)
        guard drew else { throw AssRenderError.fontsUnavailable }

        self.library = library
        self.renderer = renderer
        self.track = track
        kept = true
        appliedFrameSize = canvas
    }

    /// The queue rule holds here too: harfbuzz is built `-DHB_NO_MT`, so its
    /// shared objects have no atomic refcounts and freeing one renderer while
    /// another renders would corrupt them. Whoever drops the last reference is
    /// whoever runs this, and that is any thread, so the frees are handed to
    /// the queue. The order matters, the track belongs to the library.
    deinit {
        let library = self.library, renderer = self.renderer, track = self.track
        AssRenderer.sharedQueue.async {
            ass_free_track(track)
            ass_renderer_done(renderer)
            ass_library_done(library)
        }
    }

    /// How many events the track holds. The count libass keeps, not one of our
    /// own: it drops an event whose ReadOrder it has already seen.
    public var eventCount: Int {
        dispatchPrecondition(condition: .onQueue(AssRenderer.sharedQueue))
        return Int(track.pointee.n_events)
    }

    /// Rasterizes at this many frame pixels while the storage size keeps the
    /// author's geometry: libass scales its output bitmaps to the frame, so a
    /// frame at screen resolution draws glyphs that are never upscaled by the
    /// layer afterwards. Called whenever the host learns its pixel size moved;
    /// the generation bump is what republishes the cue on screen.
    public func setFrameSize(width: Int, height: Int) {
        dispatchPrecondition(condition: .onQueue(AssRenderer.sharedQueue))
        let target = CGSize(width: width, height: height)
        guard width > 0, height > 0, target != appliedFrameSize else { return }
        ass_set_frame_size(renderer, Int32(width), Int32(height))
        appliedFrameSize = target
        lastImage = nil
        generation &+= 1
    }

    /// Feeds one dialogue line. `event` is the subtitle packet exactly as it
    /// came off the container: an `AV_CODEC_ID_ASS` packet already is
    /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`, which
    /// is what libass reads. Field 0 is why re-reading after a seek is free.
    public func process(event: Data, start: Double, duration: Double) {
        dispatchPrecondition(condition: .onQueue(AssRenderer.sharedQueue))
        event.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            ass_process_chunk(
                track, base.assumingMemoryBound(to: CChar.self), Int32(raw.count),
                Int64((start * 1000).rounded()), Int64((duration * 1000).rounded())
            )
        }
    }

    /// Drops every event and keeps the styles and the script's resolution. A
    /// seek calls this, and the events after the target are fed again.
    public func flush() {
        dispatchPrecondition(condition: .onQueue(AssRenderer.sharedQueue))
        ass_flush_events(track)
        lastImage = nil
        generation &+= 1
    }

    /// What belongs on screen at `seconds`, or nil when nothing does. The list
    /// libass returns belongs to the renderer and is valid only until the next
    /// call, so it is consumed here and never handed on.
    public func render(at seconds: Double) -> SubtitleImage? {
        dispatchPrecondition(condition: .onQueue(AssRenderer.sharedQueue))
        var change: Int32 = 0
        let list = ass_render_frame(
            renderer, track, Int64((seconds * 1000).rounded()), &change
        )
        // The steady case: a subtitle sitting still says nothing changed, and
        // then the whole tick is this one call. libass compares against the
        // last list it drew, which survives a flush, so a bitmap of our own is
        // what makes "no change" mean anything.
        if change == 0, list != nil, let cached = lastImage { return cached }
        // 1 is libass saying every image is the one it drew last, only placed
        // elsewhere: a \move. When they all moved by one step, so did the
        // union, and the bitmap already built is the answer at a new place.
        if change == 1, let cached = lastImage {
            var stepX: Int32 = 0, stepY: Int32 = 0
            var uniform = true
            var index = 0
            var cursor = list
            while let image = cursor {
                let rect = image.pointee
                cursor = rect.next
                guard index + 1 < positions.count else {
                    uniform = false
                    break
                }
                let x = rect.dst_x - positions[index], y = rect.dst_y - positions[index + 1]
                if index == 0 {
                    stepX = x
                    stepY = y
                } else if x != stepX || y != stepY {
                    uniform = false
                    break
                }
                positions[index] = rect.dst_x
                positions[index + 1] = rect.dst_y
                index += 2
            }
            if uniform, index > 0, index == positions.count {
                let moved = SubtitleImage(
                    x: cached.x + Int(stepX), y: cached.y + Int(stepY),
                    width: cached.width, height: cached.height,
                    pixels: cached.pixels, bitmap: cached.bitmap
                )
                lastImage = moved
                generation &+= 1
                return moved
            }
        }
        let composed = compose(list)
        // Two empty frames in a row are not a change, or the end of every
        // subtitle would republish an empty screen 30 times a second.
        if composed == nil, lastImage == nil { return nil }
        lastImage = composed
        generation &+= 1
        return composed
    }

    /// Blends the list into one premultiplied BGRA bitmap of its union rect.
    ///
    /// The list is in compositing order, outlines and shadows before the glyphs
    /// they sit under, so it is walked forward and never sorted. `color` is
    /// `0xRRGGBBAA` where the last byte is transparency, not alpha. The bitmap
    /// is one byte of coverage per pixel with its own stride, and libass
    /// guarantees only `stride * (h - 1) + w` bytes, so no row is read past
    /// its width.
    ///
    /// The pixels land in a reused buffer, handed out without a copy: an
    /// animated line recomposes on every tick, and a fresh zeroed allocation
    /// of that size is page faults the blend then pays for again.
    private func compose(_ list: UnsafeMutablePointer<ASS_Image>?) -> SubtitleImage? {
        var minX = Int32.max, minY = Int32.max, maxX = Int32.min, maxY = Int32.min
        positions.removeAll(keepingCapacity: true)
        var cursor = list
        while let image = cursor {
            let rect = image.pointee
            if rect.w > 0, rect.h > 0 {
                minX = min(minX, rect.dst_x)
                minY = min(minY, rect.dst_y)
                maxX = max(maxX, rect.dst_x + rect.w)
                maxY = max(maxY, rect.dst_y + rect.h)
            }
            positions.append(rect.dst_x)
            positions.append(rect.dst_y)
            cursor = rect.next
        }
        guard maxX > minX, maxY > minY else { return nil }
        let width = Int(maxX - minX), height = Int(maxY - minY)
        let byteCount = width * height * 4
        // Not unique means a published bitmap still reads it: the layer, the
        // sink's record, a CGImage the render server has not let go of yet.
        if !isKnownUniquelyReferenced(&spare) || spare!.capacity < byteCount {
            spare = PixelBuffer(capacity: byteCount)
        }
        let buffer = spare!
        spare = drawn
        drawn = buffer
        let canvas = buffer.bytes.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        cursor = list
        while let image = cursor {
            let rect = image.pointee
            cursor = rect.next
            guard rect.w > 0, rect.h > 0, let bitmap = rect.bitmap else { continue }
            let opacity = 255 - UInt32(rect.color & 0xFF)
            guard opacity > 0 else { continue }
            let red = (((UInt32(rect.color) >> 24) & 0xFF) * whiteScale) >> 8
            let green = (((UInt32(rect.color) >> 16) & 0xFF) * whiteScale) >> 8
            let blue = (((UInt32(rect.color) >> 8) & 0xFF) * whiteScale) >> 8
            let stride = Int(rect.stride)
            let originX = Int(rect.dst_x - minX), originY = Int(rect.dst_y - minY)
            for y in 0..<Int(rect.h) {
                let row = bitmap + y * stride
                var out = canvas + ((originY + y) * width + originX) * 4
                for x in 0..<Int(rect.w) {
                    let alpha = over255(UInt32(row[x]) * opacity)
                    if alpha == 255 {
                        out[0] = UInt8(blue)
                        out[1] = UInt8(green)
                        out[2] = UInt8(red)
                        out[3] = 255
                    } else if alpha > 0 {
                        let inverse = 255 - alpha
                        out[0] = UInt8(over255(blue * alpha) + over255(UInt32(out[0]) * inverse))
                        out[1] = UInt8(over255(green * alpha) + over255(UInt32(out[1]) * inverse))
                        out[2] = UInt8(over255(red * alpha) + over255(UInt32(out[2]) * inverse))
                        out[3] = UInt8(alpha + over255(UInt32(out[3]) * inverse))
                    }
                    out += 4
                }
            }
        }
        // the deallocator is what keeps the buffer alive while any copy of
        // these bytes is, which is what the uniqueness test above reads
        let pixels = Data(
            bytesNoCopy: buffer.bytes, count: byteCount,
            deallocator: .custom { _, _ in withExtendedLifetime(buffer) {} }
        )
        return SubtitleImage(
            x: Int(minX), y: Int(minY), width: width, height: height, pixels: pixels
        )
    }
}

/// Memory compose draws into and hands out inside `Data`, freed with the last
/// reference to it. Written only while the renderer holds the one reference.
private final class PixelBuffer: @unchecked Sendable {
    let bytes: UnsafeMutableRawPointer
    let capacity: Int

    init(capacity: Int) {
        bytes = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        self.capacity = capacity
    }

    deinit { bytes.deallocate() }
}

/// `value / 255`, exact for every product of two bytes (0...65025) - which is
/// what every term of the blend above is - and without the divide. An integer
/// division is tens of cycles where this is three, and the blend runs five of
/// them per pixel of every subtitle image, thirty times a second.
@inline(__always)
private func over255(_ value: UInt32) -> UInt32 {
    (value + (value >> 8) + 1) >> 8
}
