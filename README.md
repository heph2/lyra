# Lyra

An offline iOS music player. No accounts, no subscriptions, no cloud, no telemetry.

Drop your music into the app's folder with the Files app and it plays — background audio, lock-screen controls, artwork, playlists, search. That is the whole product.

Distributed as an unsigned `.ipa` for **SideStore**. It is not on the App Store and is not built to be.

---

## What it does

- **Folder drop-in import.** "On My iPhone → Lyra" in the Files app. Drag folders in from Finder or Files; Lyra picks them up on next launch or pull-to-refresh.
- **Browse by** songs, albums, artists, or the actual folder tree on disk.
- **Playback** with queue, shuffle, repeat (off / all / one), and a reorderable up-next list.
- **Background audio** that survives locking the screen, with full lock-screen and Bluetooth transport controls.
- **Playlists** — create, rename, reorder, delete.
- **Search** across title, artist, album and genre, accent- and case-insensitive.
- **Zero network code.** No `URLSession` anywhere in the project. Airplane Mode changes nothing.

### Supported formats

MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, CAF — everything AVFoundation decodes natively.

Opus, Ogg Vorbis and WMA are **not** supported. Adding them means bundling FFmpeg, which would balloon the IPA and the build for formats that are rare in practice.

---

## Building

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

The `.xcodeproj` is generated, not committed — edit `project.yml` instead.

```bash
xcodegen generate                # regenerate Lyra.xcodeproj
open Lyra.xcodeproj              # or work from the command line:

xcodebuild -project Lyra.xcodeproj -scheme Lyra \
  -destination 'generic/platform=iOS' build
```

### Tests

```bash
xcodebuild test -project Lyra.xcodeproj -scheme Lyra \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Covers tag parsing, the FLAC header reader (against headers synthesised in the test, so no binary fixtures), library grouping, playlist ordering, and the full queue/shuffle/repeat state machine via a fake playback engine.

---

## Installing on your iPhone

```bash
./scripts/build-ipa.sh           # → build/Lyra.ipa
```

The IPA is **unsigned on purpose**. SideStore signs it with your own free Apple ID when it installs it, so no paid Apple Developer account is involved.

1. Get `build/Lyra.ipa` onto the phone (AirDrop, Files, or a SideStore server URL).
2. SideStore → **My Apps** → **+** → choose `Lyra.ipa`.
3. Refresh within 7 days — that is how long a free Apple ID certificate lasts. SideStore can refresh in the background if you have it set up.

### Getting music in

Files app → **On My iPhone** → **Lyra** → drop folders in. Or connect the phone to a Mac and use Finder's Files tab.

Any folder structure works. `Artist/Album/01 Title.flac` is ideal, because Lyra falls back to the path when a file has no tags.

---

## Notes on the design

**Track identity is the path relative to `Documents/`, never an absolute URL.** The app container's UUID changes on every reinstall, so persisted absolute URLs break. Relative paths mean your play counts and playlists survive a reinstall.

**The library database lives in Application Support, not `Documents/`.** `Documents/` is your drop zone and is visible in the Files app; it should contain your music and nothing else.

**Artwork is cached in `Caches/artwork/`, keyed by a hash of the embedded image bytes.** A twelve-track album therefore stores one JPEG, not twelve. Being in `Caches/` means iOS can reclaim it under storage pressure, and a rescan regenerates it.

**Only free-provisioning-compatible capabilities are used.** Background audio is an `Info.plist` key, not a restricted entitlement. There are no App Groups, no CloudKit, no push — none of which a free Apple ID can sign anyway.

**FLAC tags are parsed by hand.** iOS decodes FLAC audio but routinely reports no metadata for it, so `FlacTagReader` reads the STREAMINFO, VORBIS_COMMENT and PICTURE header blocks directly rather than pulling in a tag library.

**Playback sits behind a `PlaybackEngine` protocol.** Today it is a single `AVPlayer`. Gapless playback would mean an `AVAudioEngine` implementation of the same protocol, with no changes to the queue logic or the UI.

## Layout

```
project.yml              XcodeGen spec — the source of truth for the project
scripts/build-ipa.sh     unsigned archive → build/Lyra.ipa
scripts/make-icon.swift  regenerates the app icon (swift scripts/make-icon.swift)
Lyra/App/                app entry point, tab shell
Lyra/Model/              Track, Playlist, scanning, grouping
Lyra/Metadata/           tag reading, FLAC parser, artwork cache
Lyra/Playback/           engine, audio session, Now Playing, queue controller
Lyra/UI/                 SwiftUI views
LyraTests/               Swift Testing suites
```
