# Lexis for Apple TV (SwiftUI)

The tvOS app, in SwiftUI on tvOS 27, over the Rust core under `core/` and
the Swift player package under `player/`.

## Layout

- `project.yml`: the xcodegen project. `Lexis` (the app), `LexisTopShelf`
  (the Top Shelf extension) and `LexisTests`. Sources are synchronized
  folders: a new file under `Sources/` is in the build without regenerating.
- `LexisCore/`: a local Swift package around the Rust core. Everything in it
  is written by `scripts/build-core.sh`: the xcframework of the two static
  libraries, and the Swift bindings UniFFI generates over them.
- `Sources/App/`: the app entry, the shell (tabs, levels, player), the
  theme tokens, the string catalog (`Catalog.swift`, English and French,
  edited by hand) and the preferences.
- `Sources/Core/`: the core client, the artwork loader, the formatting.
- `Sources/Components/`: what every screen draws with.
- `Sources/Screens/`: one file per screen, panes and the player beside them.
- `Sources/Player/`: the bridge between the player package and a view.
- `TopShelf/`: the extension, reading `shelf.json` from the app group.

## Building

```sh
brew install xcodegen
tv/scripts/build-core.sh      # cargo for tvOS and its simulator, bindings
cd tv && xcodegen generate && open Lexis.xcodeproj
tv/scripts/install-tv.sh      # Release build installed on the Apple TV "TV"
tv/scripts/trace-tv.sh start  # launch it with the trace on: hangs, hitches, CPU per thread
tv/scripts/trace-tv.sh fetch  # copy the trace to tv/.trace/
```

## Preferences

UserDefaults, one key per choice: `ui.language.v1`, `audio.passthrough.v1`,
`video.upscaling.v1`, `video.neuralUpscaling.v1`, `video.dolbyVision.v1`,
`search.recent.v1`, and the core's own state through
its host store.

The picture and sound settings are one pane, Video & Audio: every switch
on one screen (upscaling, neural upscaling, Dolby Vision, audio output), then
what the sound output takes, what the last film was played as, and what to
change outside Lexis.
