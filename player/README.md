# Lexis player

The tvOS playback pipeline: FFmpeg demuxing, VideoToolbox decoding and an
`AVSampleBufferDisplayLayer` sink, plus a TestBench app that runs it on screen.

## Build prerequisites

`Vendor/FFmpeg.xcframework`, `Vendor/LibASS.xcframework` and the C headers under
`Sources/CFFmpeg/include` and `Sources/CLibass/include` are build products, not
sources, and none of them is committed. Build them once before opening the Swift
package or the TestBench project, or resolution fails on a missing binary
target:

```bash
bash scripts/build-ffmpeg.sh
bash scripts/build-libass.sh
```

The first downloads FFmpeg 7.1.5; the second downloads libass 0.17.4, FreeType
2.13.3, HarfBuzz 10.4.0 and FriBidi 1.0.16. Both build macOS, tvOS and tvOS
simulator slices, take a while the first time, and are a no-op afterwards. The
FFmpeg framework ships under LGPL 2.1 (`FFMPEG_NOTICE.txt` inside each slice);
the LibASS framework carries four licences, ISC, FTL, Old MIT and LGPL 2.1
(`LIBASS_NOTICE.txt` and the four `COPYING.*` files inside each slice).

The tests also link the core's stream ABI (`core/include/lexis_stream.h`), so
build the core once too:

```bash
cd ../core && cargo build && cd ../player
```

Only the test target links it; `LexisPlayer` itself and TestBench do not. The
dylib's install name is absolute, so a checkout that moved needs `cargo build`
run again before the tests link.

Then:

```bash
swift test                        # the package, on macOS
LEXIS_REALTIME_TESTS=1 swift test # with the real-time tests too
cd TestBench && xcodegen generate # regenerate TestBench.xcodeproj
```

Some tests spend real wall clock because the wall clock is what they assert
on: a stall that has to outlast the lead the reader can build, a grace period
that has to elapse before nothing having happened means anything, a film
delivered at the rate it would really be delivered at. They are the bulk of
the suite's runtime, so they are asked for rather than run by default.
`swift test` alone runs in about ten seconds; with `LEXIS_REALTIME_TESTS` set
it runs for a few minutes, which is what CI should run.

Most of them are told at a scale of their own rather than at a film's. The
spans the engine reasons in are all on `BufferPolicy`, and `testTimeScale`
divides every one of them - watermarks, read-ahead window, first-picture grace
- along with the length of the fixtures they play, so a stall that has to
outlast the reader's lead still does at an eighth of the wall clock. What
survives that is what does not scale: the renderer's own clock, which is the
operating system's, and the one test needing two stalls far enough apart that
each causes its own pause, whose margin is thin at full length and inverts if
you divide it.

`swift test --parallel` runs the real-time lane several times faster, but a
couple of these assert on delivery timing and drift when eleven other tests
are competing for the machine, so it is not the default.

Fixture encodes are cached between runs, under a temporary directory named for
a digest of the code that writes them, so only the first run after a change to
that code pays for them.

`xcodegen` comes from `brew install xcodegen`; the committed
`TestBench.xcodeproj` is generated from `TestBench/project.yml`, so edit the
yaml and regenerate rather than the project.

Building or running TestBench needs the tvOS platform support component, which
Xcode does not install by default: Xcode > Settings > Components > tvOS.

## Streams

`Demuxer` and `LexisPlayer` open either a path or a stream. A stream is a
`MediaStreamIO`: an opaque handle and four C function pointers (read, seek,
size, close), which `AVIOStream` hands to FFmpeg as a custom AVIO context with
a 256 KiB buffer. Opening a stream takes ownership of it: it is closed when the
demuxer goes away, and also when the open throws.

The player does not know what is behind the handle and does not link the core.
The core's own implementation is `core/src/ffi/mod.rs`, declared in
`core/include/lexis_stream.h`, and `LexisCoreStream` is the product that joins
the two: `coreStream(handle:)` turns a `LexisStream *` into a `MediaStreamIO`.
Depending on `LexisCoreStream` is what puts the core's symbols in a target's
way: it imports `CLexisStream`, whose module map only declares the header, so
whoever depends on it has to bring the library itself. Here that is the test
target in `Package.swift`, whose `-L core/target/debug -llexis_core` is the only
place the core is linked at all. `LexisPlayer` alone, which is all TestBench
depends on, needs none of it.

Opening and stopping both block: `avformat_open_input` probes the container
through the stream, and `stop()` waits for the reader. Call them off the main
thread. An `InterruptFlag` bounds the wait: `stop()` and `cancel()` raise it,
`play()` and `open(stream:)` lower it, and a raised flag makes the next read
give up. It cannot cut a read already inside the stream, so the bound is one
outstanding read, not zero, and `stop()` gives up waiting just past the core's
own read timeout rather than never returning.

A refused read latches inside the AVIOContext and lowering the flag does not
clear it, so a stream a `stop()` or a `cancel()` cut short is spent: `play()`
refuses it in silence, exactly as after an end of stream, and `open(stream:)`
is the way back. A file opened by path is untouched by this.

A stopped player still holds its stream and its container: the socket stays
open until something opens another stream or calls `close()`, which stops and
then lets go of everything the open left behind. An app that parks a player it
is done with has to call it.

## Codecs and sound

Video plays through the display layer for H.264, HEVC and AV1 (the `av1C`
travels as the extradata FFmpeg hands over); a codec the device has no
hardware decoder for goes through `SoftwareVideoDecoder` instead - dav1d for
AV1 - straight into pooled IOSurface buffers, zero-copy for 8-bit 4:2:0 and a
shift-and-interleave copy into biplanar 10-bit for ten bit tracks, with the
stream's colour tags attached so an HDR picture reads as one. Interlaced
tracks on that path are deinterlaced per field by a median filter: static
detail weaves through at full resolution, motion is clamped combless.

A small SDR picture on a screen with far more pixels takes the upscaled path:
Prisme, the player's own scaler (`Upscaler.swift`), doubles it before it is
enqueued. A network on the Neural Engine doubles the luma where it keeps up
with the film (`setNeuralUpscaling`); elsewhere filters learned against true
4K do it on the GPU, and a 720p or SD picture is then finished to the screen
by Lanczos 3. A GPU older than the ones MetalFX's own scaler takes keeps the
path where the compositor scales. SDR only, on by default and switchable with
`setUpscalingAllowed`; `stats.videoUpscaled` says whether a file got it.
`Tools/prisme` trains both, and says what each measured.

Audio decodes to interleaved float PCM with a real CoreAudio channel layout -
named channels up to 7.1 and beyond, so the system can downmix what the route
cannot carry. AC-3 and E-AC-3 may ride to the route compressed
(`passthroughAllowed`), and a route that refuses them falls back to the
decoder on the renderer's own error; DTS is always decoded, the Apple TV's
renderer stalling on its bitstream.

The track a file opens on is weighed against the route the app reads from
its audio session (`setAudioRoute`: the PCM channels it carries, and whether
a Dolby bitstream goes on to a receiver). Over HDMI ARC only a compressed
Dolby stream carries more than two channels, so where the route would fold
the first track's decoded sound to stereo, a Dolby track in the same
language is preferred, even over a lossless one; a route that decodes
everything keeps the lossless track. `stats.audioChannels` and
`stats.audioRouteLimited` say what leaves and whether the route folded it.

## HDR and Dolby Vision

The colour a container declares (primaries, transfer, matrix, range) and the
two static HDR payloads (`mdcv` and `clli`) travel from `codecpar` onto the
`CMVideoFormatDescription`. Without them VideoToolbox invents a colour space,
and it invents an SDR one, so an HDR10 file used to be shown as Rec. 601.

A Dolby Vision track is recognised from its `dvcC` or `dvvC` box, which FFmpeg
hands over as `AV_PKT_DATA_DOVI_CONF`. On a screen that does Dolby Vision, a
profile 5 or 8 stream is described as `dvh1` (the `hvcC` and the record
together) so the platform's own decoder reads the RPU and the display is
asked for Dolby Vision; the description is probed once at open and the mapped
or plain path stands in where the device refuses it. Elsewhere, a profile 8
base layer (8.1, 8.2, 8.4) keeps its record beside the `hvcC` on an `hvc1`
entry. Profile 7, what a UHD Blu-ray carries, goes to the display as the HDR10
its base layer is, with no record: the enhancement layer is not read here and
a record promising one would describe samples the decoder never gets.

When the screen cannot show what the file holds, which is every simulator and
every SDR display, the player takes the other path: `VideoDecoder` decodes
into 10-bit buffers, a Metal kernel maps each frame with ITU-R BT.2390's EETF
between the brightness the frame's RPU declares and the headroom the screen
reports, and the sink is handed the resulting picture. The curve runs on
max(R,G,B) and the other channels follow by the same factor, so a mapped
highlight keeps its hue; on an SDR destination the 8-bit store is dithered
with blue noise so a flat gradient does not band. Profile 5 takes that path
wherever the screen does not do Dolby Vision, because its base layer is not a
picture any ordinary display can show, and its colours come out of the IPT
chain libplacebo decodes: each component through the RPU's reshaping curve,
polynomial or MMR between pivots, then the RPU's matrix, PQ to light, and the
RPU's LMS into BT.2020 by Dolby's lms2rgb times the RPU's rgb_to_lms. A
mapped picture stored as half floats is declared to the layer as high dynamic
range, so what the curve placed above white is shown rather than clipped.

HLG has its own EOTF in the same kernel (inverse OETF and the 1000-nit
reference OOTF) and follows the same rule: passthrough on a screen with
headroom, mapped on one without.

On tvOS an HDR stream the screen could show as it is takes a third path,
`decoded`: `VideoDecoder` decodes it in a session of our own, to 10-bit
YCbCr, and the pictures go to the layer untouched, with the mastering display
and content light attached. Measured on an Apple TV 4K: a display layer
decoding an HEVC stream for itself drops frames wherever the stream reorders
through a deep B pyramid (22% of a 4K clip with eight B frames per mini-GOP,
identical figures whether the samples came from this player or from
`AVAssetReader`), and a session of our own drops none. A Dolby Vision
profile 8 stream keeps its `dvh1` description on this path: VideoToolbox is
where the record is read whichever side of the layer it runs, and the
pictures it hands back carry the per-frame RPU data, the compatibility id
and any HDR10+ payload as attachments, which the layer's own Dolby Vision
processing reads. Profile 5, whose base layer is no picture without the
record, stays with the display layer. The decoded path also carries the
enhanced rendering (`setRendering(.enhanced(peakNits:))`, the player's one
rendering switch, faithful by default): libplacebo's single pivot spline,
pivoted on the scene's average and aimed at the display's real peak rather
than the grade's, and stored
back as ten bit PQ YCbCr with static metadata for that peak, so the display
shows it as it is instead of fitting a 4000 nit grade onto 300 nits with its
own curve. The record is left off on that path, the film goes as HDR10.

The same switch takes an SDR film the screen would show as it is down a
fourth path, `enhanced`: decoded here at its own depth, the bands of the luma
and the chroma smoothed at a distance drawn per pixel, the luma then
sharpened by AMD's contrast adaptive sharpening in near linear light, less on
a pixel that stands alone, and stored as ten bit under two codes of blue
noise grain, in the stream's own colour (`PictureEnhancer`). A small SDR film
still goes up the upscaler when that switch is on; where the system's scaler
takes it, Enhanced debands and grains it at its own size first, without
sharpening, which the scaler does, stored at the eight bits the scaler takes,
the grain being exactly the half code of dither that store needs.

What the dynamic curve is built from, per frame: on a Dolby Vision stream the
level 1 block of the frame's RPU (its peak and mean, forgotten where the
block flags a scene change); on an HDR10+ stream the scene's peak and mean
its payload states (the highest percentile at or past 99 and the average
maxRGB); on any other stream a histogram of the frame itself, counted on the
GPU ahead of the pass that maps it (the peak at the 99.995th percentile, the
mean above a black cutoff), both smoothed over the time twenty frames of film
last, a jump of the mean weighed by the part of the frame it lights taken as
a cut, so a cut is mapped for the shot it opens from its first picture rather
than a decoder's depth of frames later. A scene that peaks under the display
is lifted toward the display's peak, by a fifth at most and never past a mean
of four tenths of the display's range in PQ, so only a dark scene moves; its
black lands on zero, the display applying its own. The dynamic curve does its
colour work in ICtCp, where the hue never moves: a pixel it compresses has
its chroma scaled by libplacebo's hull rule, min(I0 / I1, hull(I1) /
hull(I0)) with hull(x) = x (x - 3)^2. It runs partly on a base of the picture
(a guided filter over the frame at a sixteenth) so detail inside a bright
field the knee compresses keeps its contrast, within a bounded reach of the
frame's own curve and never past the display's peak. Over that, libplacebo's
contrast recovery lays back three tenths of the fine detail the curve
flattens: the curve runs on the picture at a quarter and the detail over it
is added back. On a screen without headroom the same Enhanced rendering maps
onto SDR white, and compresses BT.2020 into the BT.709 the screen shows with
ACES's reference gamut compression rather than leaving the system to clip it.
The faithful rendering is BT.2390 as written. Both renderings read chroma
through a Catmull-Rom kernel held inside its nearest samples, and the ten bit
store is dithered with the same blue noise as the eight bit one. The PQ
picture's chroma is subsampled sited left, the MPEG-2 siting every decoder
assumes, and tagged so.

On tvOS every
HDR path, this one included, is composited rather than scanned out from the
display's video plane; `AVVideoPerformanceMetrics` counts zero optimized
frames for HDR content however the layer is fed, SDR content is optimized.

tvOS takes every decoder back while the app is off screen. On the display
layer's own path the renderer says so and the sink flushes it back in; on
the paths that decode here the session answers `kVTInvalidSessionErr`, which
the engine reports as a decoder taken back rather than a failed film, and
the path is turned round from where the clock stands.

The screen is read at open, and read again when the platform reports a display
change: `displayConfigurationChanged` re-decides the path and turns the file
round without re-opening the stream, the same way the Dolby Vision fallback
does. `dynamicRange` reports what the open file is.

The display layer's `preferredDynamicRange` is set to `.high` on every path
that hands over an HDR picture, and `.standard` where the picture was mapped
down for the screen. `potentialEDRHeadroom`, the one number that decides the
path for every file, has only ever been read on a simulator, where it answers
1.0; on tvOS the path is decided by `eligibleForHDR` instead.

What the tone map and the enhancer cost is read off each pass's own
command buffer: `PlaybackStats` carries the mean and the worst per picture,
and a `[lexis.gpu]` line traces them every 240 passes on the device.

Nothing about what appears on screen is testable headless. The tests pin the
format descriptions, the RPU values (against libavcodec's own parser, except
the NLQ walk, which has no reference to check against) and the kernel's
arithmetic (against a CPU implementation of the same recommendation).
