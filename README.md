<p align="center"><img src="docs/assets/icon.png" alt="Lexis" width="240"></p>

# Lexis

**A media player for Apple TV that knows your library, your setup and your taste.**

> **Early release, work in progress.** Lexis is used daily on one household's
> Apple TV, but it is not on the App Store, has no binary release, and its APIs,
> storage format and settings change without notice. Expect rough edges, and
> expect to build it yourself.

Lexis plays the films and series you already own, from a Plex server or a
local share, on tvOS. It is not a Plex client with a new skin: it brings its
own playback pipeline, its own library index and its own recommendations,
all running on the Apple TV.

## Why Lexis is different

### It plays the file, not a transcode

Lexis has its own player: FFmpeg demuxing, VideoToolbox decoding, an
`AVSampleBufferDisplayLayer` sink. The file is read as it is, so what reaches
the screen is what is in the file.

- **Dolby Vision, done properly.** Profiles 5, 7 and 8 each take the path
  they need: native Dolby Vision on a screen that does it, the HDR10 base
  layer for profile 7, and a full IPT reshaping chain (from the RPU) for
  profile 5 where the screen cannot show it.
- **Real tone mapping.** On a screen with less headroom than the content,
  frames are mapped in a Metal kernel with ITU-R BT.2390's EETF, hue
  preserving, with blue-noise dithering on SDR so gradients do not band. HLG
  gets its own EOTF.
- **Sound that fits the route.** Multichannel PCM with real channel layouts,
  AC-3 / E-AC-3 passthrough, and track choice weighed against what the HDMI
  route can actually carry (a Dolby track over ARC rather than a lossless one
  folded to stereo).

### What it plays

Any container and codec FFmpeg 7.1 reads. The hardware path is chosen per
file, by asking VideoToolbox on the device itself, never from a table.

| | Hardware (VideoToolbox) | Software (FFmpeg) |
| --- | --- | --- |
| Video | H.264, HEVC 8 and 10 bit, AV1 where the chip decodes it | AV1 through dav1d (the Apple TV 4K's A15 has no AV1 decoder), VP9, MPEG-2, VC-1 and the rest of FFmpeg's decoders, interlaced sources deinterlaced or inverse-telecined |
| HDR | HDR10, HLG, Dolby Vision 5, 7 (base layer) and 8 | the same pictures tone mapped on the GPU where the screen cannot show them |

| Audio | Sent as is to the receiver | Decoded to multichannel PCM |
| --- | --- | --- |
| Dolby Digital, Dolby Digital Plus (Atmos included) | yes, when the route takes it | otherwise |
| Dolby TrueHD | offered; decoded if the route refuses it | otherwise |
| DTS, DTS-HD | never: the Apple TV's renderer stalls on it | always, every channel kept |
| AAC, FLAC, Opus, PCM and the rest | | always |

Subtitles: text (SRT and friends), styled ASS/SSA through libass, and
bitmap PGS from Blu-ray.

### Prisme, a learned upscaler running on the Apple TV

A 1080p film on a 4K screen is doubled by Prisme, Lexis's own scaler, not by
the TV. A small network on the Neural Engine doubles the luma in real time
(13 to 14 ms a frame on an Apple TV 4K, A15); where it cannot keep up, filters
learned in the manner of RAISR and BLADE take its place on the GPU. Both were
trained against true 4K, on clean masters and on starved encodes, and the
stream's own starvation decides how much detail is restored.

Measured on held-out films, VMAF NEG against true 4K:

| | Prisme filters | Prisme network |
| --- | --- | --- |
| clean 1080p source | 97.8 | 99.2 |
| encoded 1080p source | 89.1 | 89.0 |

The filters alone already beat the Lanczos and sharpen they replaced (96.99
to 97.81 on clean sources) with a sixth of the overshoot.

The training pipeline, the dataset recipe and every approach tried and
dropped are in [`player/Tools/prisme`](player/Tools/prisme/README.md): you can
train your own banks on your own films.

### It tells you what your setup gets

One settings pane, *Video & Audio*, holds every switch on one screen, each
with its default already right (upscaling, Dolby Vision or HDR10, Dolby to
the receiver or decoded), and says in plain words what the sound output
takes: whether the receiver gets Dolby as it is, how many decoded channels
the route carries, what the last film was played as, and what to change
outside Lexis when the route is the limit.

### Recommendations that stay on the device

The home is not a grid of "recently added". It is rows of posters, each named
by *why* it is there, built from your library, what you watched and how you
rated it.

- A multilingual sentence encoder (`multilingual-e5-small`, Apache-2.0) runs
  **on the Apple TV**, in Rust, over your synopses. No account, no cloud, no
  telemetry. Lexis works without it too, falling back to metadata links and
  genres.
- No language model and no server of ours: questions typed in words
  ("something funny under 1h40, not seen") are read by local rules and the
  same encoder.

### Built to be fast

The core is Rust over SQLite, exposed to Swift through UniFFI. Background
work (scans, metadata, embeddings) runs at utility priority and is resumable,
so the interface and playback come first. Performance claims in the docs are
measured, with the conditions noted.

## How it compares

Lexis is not the only good way to watch your own files on an Apple TV.
Here is where it sits, honestly:

| | Lexis | Infuse | Plex app | Swiftfin |
| --- | --- | --- | --- | --- |
| Source code | Open (MIT) | Closed | Closed | Open (MPL) |
| Price | Free | Free tier, Pro subscription | Free at home; Plex Pass or Remote Watch Pass away from home | Free |
| Sources | Plex, local | Plex, Jellyfin, Emby, SMB, NFS, FTP, WebDAV, cloud | Plex | Jellyfin |
| Playback | Its own pipeline, direct play | Its own pipeline, direct play or server transcode | Plex player, may transcode | AVKit or VLCKit player, your pick |
| Recommendations | On-device, from your library and ratings | Metadata, Trakt | Plex's online Discover | Jellyfin's own |
| Maturity | Early, build it yourself | Years of polish, App Store | App Store | App Store |

**Choose Infuse** if you want something polished that plays everything from
everywhere today: it is the reference, and Lexis does not try to match its
range of sources or formats. **Choose Lexis** if you care about what Lexis
cares about: recommendations that know your shelf and never leave the device,
a player whose HDR and audio decisions are written down and open to read, and
a codebase you can change.

Checked in November 2026 against release notes and press coverage;
they move too. Lexis reads from a Plex server, so Plex's rules for remote
playback apply to it as to any other client.

## Layout

| Path | What it is |
| --- | --- |
| [`core/`](core) | Rust library: sources (Plex, local), index, metadata, embeddings, recommendations, stream ABI |
| [`player/`](player/README.md) | Swift package: the playback pipeline, plus a TestBench app |
| [`tv/`](tv/README.md) | The tvOS app in SwiftUI, and its Top Shelf extension |
| [`docs/`](docs) | The embedding model, and the icon the README shows |

## Building

Requirements: macOS with Xcode and the tvOS platform component, tvOS 27.1 or
later on the device, a Rust toolchain, and `brew install xcodegen meson ninja`.

```sh
# the player's native dependencies (FFmpeg, libass), once
cd player && bash scripts/build-ffmpeg.sh && bash scripts/build-libass.sh && cd ..

# the Rust core for tvOS and its Swift bindings
tv/scripts/build-core.sh

# the app
cd tv && xcodegen generate && open Lexis.xcodeproj
```

The app reads a TMDB read token from `tv/Secrets.xcconfig`, which is not
committed: copy `tv/Secrets.example.xcconfig` and fill it in. See
[`CONTRIBUTING.md`](CONTRIBUTING.md) for the full setup and the checks.

## Status

Working today: Plex and local sources, browsing, search, detail pages,
playback with HDR / Dolby Vision / multichannel audio, subtitles,
on-device recommendations, English and French interface.

## Roadmap

No dates, and the order may change. Roughly, next:

- **Distribution**: a TestFlight build, so trying Lexis does not mean
  building it.
- **Stable storage**: a versioned index format with migrations, so an update
  never asks for a rescan.
- **Lighter recommendations**: a smaller packaged encoder (about 134 MiB
  instead of 465 MiB, measured in [`docs/embedding-model.md`](docs/embedding-model.md))
  and a tokenizer that does not hold 388 MiB resident.
- **More sources**: SMB and Jellyfin are the likely first ones after Plex and
  local files.
- **Android TV and Google TV**: a second app over the same Rust core, which
  already holds the sources, the index and the recommendations; only the
  interface and the player are per platform.
- **Dolby Vision profile 7**: reading the enhancement layer rather than
  playing the HDR10 base layer.

Later, maybe: the App Store, more interface languages, iPad and Mac.

## Contributing

Issues and discussions are welcome. Pull requests too, but open an issue
first for anything large: the design still moves. [CONTRIBUTING.md](CONTRIBUTING.md)
explains how the pieces fit, the setup and the checks.

## Licence

Lexis is released under the [MIT licence](LICENSE).

Built artifacts pull in third-party code under their own licences: FFmpeg
(LGPL 2.1), libass and its dependencies (ISC, FTL, MIT, LGPL 2.1), and the
embedding model (Apache-2.0), downloaded at runtime and never bundled. Lexis
is not affiliated with Plex, Dolby or Apple.
