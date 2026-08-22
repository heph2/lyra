# Lyra

An offline-first iOS music player. No accounts, no subscriptions, no cloud, no telemetry.

Use music from Lyra's Files folder, another local folder, or a WebDAV library. Remote tracks are indexed without being downloaded, and only the tracks or albums selected for offline use consume device storage.

Distributed as an unsigned `.ipa` for **SideStore**. It is not on the App Store and is not built to be.

---

## What it does

- **Folder drop-in import.** "On My iPhone → Lyra" in the Files app. Drag folders in from Finder or Files; Lyra picks them up on next launch or pull-to-refresh.
- **External folder libraries.** Index a folder chosen from the document picker without copying or moving its files.
- **WebDAV libraries.** Browse a remote library and selectively download tracks or albums for offline playback.
- **Browse by** songs, albums, artists, or the actual folder tree on disk.
- **Playback** with queue, shuffle, repeat (off / all / one), and a reorderable up-next list.
- **Background audio** that survives locking the screen, with full lock-screen and Bluetooth transport controls.
- **Playlists** — create, rename, reorder, delete.
- **Search** across title, artist, album and genre, accent- and case-insensitive.
- **Network access is isolated to WebDAV.** Local and downloaded music works in Airplane Mode. Lyra has no analytics or backend.

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

### SideStore source

Tagged GitHub releases publish an unsigned IPA and a SideStore source. After the first release, add this URL to SideStore once:

```text
https://github.com/OWNER/REPO/releases/latest/download/source.json
```

Replace `OWNER/REPO` with this repository's GitHub location. SideStore will then discover later tagged Lyra versions from the same source and can download and sign updates itself. The repository and its release assets must be publicly downloadable because SideStore cannot authenticate to a private GitHub repository.

SideStore still has to refresh apps within the free Apple ID's seven-day signing window. The source removes the manual IPA transfer step; it does not remove Apple's signing limit.

### Manual IPA

```bash
./scripts/build-ipa.sh           # → build/Lyra.ipa
```

The IPA is **unsigned on purpose**. SideStore signs it with your own free Apple ID when it installs it, so no paid Apple Developer account is involved.

1. Get `build/Lyra.ipa` onto the phone (AirDrop, Files, or a SideStore server URL).
2. SideStore → **My Apps** → **+** → choose `Lyra.ipa`.
3. Refresh within 7 days — that is how long a free Apple ID certificate lasts. SideStore can refresh in the background if you have it set up.

### Getting music in

Files app → **On My iPhone** → **Lyra** → drop folders in. Or open **Library Sources** in Lyra to select another local folder or add a WebDAV server.

Any folder structure works. `Artist/Album/01 Title.flac` is ideal, because Lyra falls back to the path when a file has no tags.

WebDAV downloads live in Lyra's private container under `Application Support/Libraries/<library-id>/Music/`, preserving the remote folder structure. They do not appear in the Files drop zone. Removing an offline download or its WebDAV source removes Lyra's managed copy; it never changes the server's file.

## Releases and CI

[`.github/workflows/ipa.yml`](.github/workflows/ipa.yml) tests and packages every push and pull request on a macOS 26 runner. A semantic-version tag such as `v1.1.0` additionally creates or updates a GitHub Release containing:

- `Lyra.ipa` — unsigned, ready for SideStore to sign
- `Lyra.dSYMs.zip` — symbols for device crash reports
- `source.json` — the stable SideStore update source
- `icon.png` — artwork referenced by the source

Create a release by pushing a new version tag:

```bash
git tag v1.1.0
git push origin v1.1.0
```

Each release tag must increase the semantic version. SideStore compares `CFBundleShortVersionString`, not only the internal build number, when deciding whether an update exists.

## Diagnostics

Lyra writes privacy-safe unified logs for app startup, library scans, WebDAV response status and byte counts, offline downloads, and playback failures. Logs deliberately exclude credentials, server URLs, source names, and track paths. Use macOS Console with the connected iPhone selected and filter for a subsystem beginning with `care.davinci.lyra`; SideStore may append its signing-team suffix to the installed bundle identifier.

---

## Notes on the design

**Track identity is a source-qualified relative path, never an absolute URL.** The app container's UUID changes on every reinstall, so persisted absolute URLs break. Relative paths keep local and remote source identities stable.

**The library database lives in Application Support, not `Documents/`.** `Documents/` is your drop zone and is visible in the Files app; it should contain your music and nothing else.

**Artwork is cached in `Caches/artwork/`, keyed by a hash of the embedded image bytes.** A twelve-track album therefore stores one JPEG, not twelve. Being in `Caches/` means iOS can reclaim it under storage pressure, and a rescan regenerates it.

**Only free-provisioning-compatible capabilities are used.** Background audio is an `Info.plist` key, not a restricted entitlement. There are no App Groups, no CloudKit, no push — none of which a free Apple ID can sign anyway.

**FLAC tags are parsed by hand.** iOS decodes FLAC audio but routinely reports no metadata for it, so `FlacTagReader` reads the STREAMINFO, VORBIS_COMMENT and PICTURE header blocks directly rather than pulling in a tag library.

**Playback sits behind a `PlaybackEngine` protocol.** Today it is a single `AVPlayer`. Gapless playback would mean an `AVAudioEngine` implementation of the same protocol, with no changes to the queue logic or the UI.

## Layout

```
project.yml              XcodeGen spec — the source of truth for the project
scripts/build-ipa.sh     unsigned archive → build/Lyra.ipa
scripts/make-sidestore-source.swift  release metadata → source.json
lyra-logo.png            source artwork for the app icon
scripts/make-icon.swift  lyra-logo.png -> AppIcon.png (swift scripts/make-icon.swift)
Lyra/App/                app entry point, tab shell
Lyra/Diagnostics/        privacy-safe unified logging categories
Lyra/Model/              Track, Playlist, scanning, grouping
Lyra/Metadata/           tag reading, FLAC parser, artwork cache
Lyra/Playback/           engine, audio session, Now Playing, queue controller
Lyra/UI/                 SwiftUI views
LyraTests/               Swift Testing suites
```
