# Contributing to Lexis

Lexis is an early release: the design still moves, so open an issue before
anything large. Small fixes can go straight to a pull request.

## How the pieces fit

```
tv/       SwiftUI app (tvOS)      -> calls the core through UniFFI bindings
player/   Swift playback package  -> reads bytes through the core's stream ABI
core/     Rust library            -> sources, SQLite index, metadata, embeddings, recommendations
```

- **core** owns all state: the library index (SQLite), metadata from TMDB,
  the embeddings and every recommendation row. The app asks, the core
  answers. Its public surface is `core/src/api/`; storage and queries live in
  `core/src/index/`. Sources (Plex, local files) implement the module in
  `core/src/source/`.
- **player** knows nothing about the library: it gets a `MediaStreamIO` (read,
  seek, size, close) and plays it. `player/README.md` explains the pipeline,
  HDR and audio decisions in depth.
- **tv** is the interface: `Sources/Screens/` one file per screen,
  `Sources/Components/` shared views, `Sources/App/Theme.swift` the design
  tokens, `Sources/App/Catalog.swift` every string in English and French.

## Setup

macOS with Xcode and its tvOS component, a Rust toolchain with the tvOS
targets, and xcodegen:

```sh
rustup target add aarch64-apple-tvos aarch64-apple-tvos-sim
brew install xcodegen meson ninja
cd player && bash scripts/build-ffmpeg.sh && bash scripts/build-libass.sh && cd ..
cd core && cargo build && cd ..
tv/scripts/build-core.sh
cp tv/Secrets.example.xcconfig tv/Secrets.xcconfig   # add a TMDB read token
cd tv && xcodegen generate && open Lexis.xcodeproj
```

The FFmpeg and libass builds take a while the first time and are no-ops
afterwards.

## Checks

The same ones CI runs (`.github/workflows/ci.yml`):

```sh
cd core && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked
cd player && swift test                         # about ten seconds
cd player && LEXIS_REALTIME_TESTS=1 swift test  # the real-time lane, a few minutes
bash tv/scripts/check-spacing.sh
```

The app's own tests run from Xcode (scheme `Lexis`, a tvOS simulator), or as
CI does it with `xcodebuild test`.

## Conventions

- **Simple and fast.** The simplest design that is also the fastest. No
  abstraction for later, no helper that wraps one call. A performance claim
  comes with a measurement: same machine, several runs, the median.
- **Comments** say what the code cannot: a constraint, a non-obvious why.
  Never what the next line does, never history.
- **Interface**: spacing comes from `Theme.Space`, never a literal (that is
  what `check-spacing.sh` enforces). Every new string goes in `Catalog.swift`
  in both English and French.
- **Code** is in English: identifiers, comments, commits.
- **Commits and PR titles** follow
  [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):
  `fix(player): keep the subtitle track across a seek`.

## Licence

By contributing you agree that your work is released under the
[MIT licence](LICENSE).
