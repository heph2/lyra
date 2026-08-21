# Working on Lyra

Offline iOS music player. No accounts, no subscriptions, no network code, no App Store. Sideloaded as an unsigned `.ipa` via SideStore.

Read this before changing anything. Most of it was learned by breaking the app.

---

## Hard constraints

These are not preferences. Violating them breaks the product or the build.

- **No network code.** `grep -rE "URLSession|dataTask|CFNetwork" Lyra` must stay empty until WebDAV lands (see `ROADMAP.md`), and even then it must be confined to the WebDAV source. The app has to work fully in Airplane Mode.
- **No third-party dependencies.** AVFoundation, SwiftUI, SwiftData, MediaPlayer, CryptoKit, ImageIO. Nothing else.
- **Free-provisioning only.** SideStore signs with a free Apple ID, so no App Groups, no CloudKit, no push, no Sign in with Apple. Background audio works because it is an `Info.plist` key (`UIBackgroundModes: audio`), not a restricted entitlement. Adding a restricted entitlement makes the app unsignable.
- **Never copy, move, or delete the user's files.** Lyra indexes and plays. The files are theirs.
- **iOS 26 deployment target, Swift 6 strict concurrency.** Both are set in `project.yml`.

## Commands

```bash
xcodegen generate                    # REQUIRED after adding/removing any file
xcodebuild -project Lyra.xcodeproj -scheme Lyra \
  -destination 'generic/platform=iOS' build
xcodebuild test -project Lyra.xcodeproj -scheme Lyra \
  -destination 'platform=iOS Simulator,name=iPhone 17'
./scripts/build-ipa.sh               # -> build/Lyra.ipa, unsigned
swift scripts/make-icon.swift        # lyra-logo.png -> AppIcon.png
```

`Lyra.xcodeproj` is generated and gitignored. `project.yml` is the source of truth. **A new `.swift` file that is not in the project fails with `cannot find 'X' in scope` — run `xcodegen generate` before believing a "missing type" error.**

## Layout

```
project.yml              XcodeGen spec
lyra-logo.png            icon source art
scripts/                 build-ipa.sh, make-icon.swift
Lyra/App/                LyraApp (entry, ModelContainer), RootView (tabs, sheets)
Lyra/Model/              Track, Playlist, MusicSource/SourceRegistry,
                         LibraryStore (@ModelActor), LibraryScanner, LibraryGrouping, AudioFile
Lyra/Metadata/           MetadataReader, FlacTagReader, ArtworkCache, TrackMetadata
Lyra/Playback/           PlaybackEngine (protocol + AVPlayer), PlayerController,
                         AudioSessionManager, NowPlayingCenter
Lyra/UI/                 SwiftUI views
LyraTests/               Swift Testing (not XCTest)
```

## Invariants

**Track identity is a source-qualified path, never an absolute URL.** The app container UUID changes on every reinstall, so a stored absolute URL is garbage tomorrow. Drop-zone tracks keep a bare relative path (`Artist/Album/01 Song.flac`); external-folder tracks are prefixed `@<source-id>/`. A real relative path never starts with `@`, so they cannot collide. Use `AudioFile.trackPath(sourceID:innerPath:)` / `AudioFile.split(trackPath:)` — never string-munge it by hand.

Keeping drop-zone paths bare is deliberate: it means libraries and playlists written before external folders existed still load, with no SwiftData migration.

**Playlists store paths, not SwiftData relationships.** The path is already stable identity. `Playlist.resolveTracks(in:)` drops paths whose files are gone.

**An unreachable source is not an empty source.** `planScan()` holds back removals for sources that failed to resolve. Without this, unplugging a drive marks every track deleted and guts every playlist referencing them.

**The SwiftData store lives in Application Support, not `Documents/`.** `Documents/` is the user's drop zone, visible in the Files app, and must contain only their music. Application Support **does not exist in a fresh container** — `LyraApp.makeContainer()` creates it explicitly, or the store silently fails open into memory and the library evaporates every launch.

**All SwiftData mutation happens in `LibraryStore`, a `@ModelActor`.** Tag parsing — the expensive part — runs in a bounded `TaskGroup` in `LibraryScanner`, off the model actor.

## Gotchas that have already bitten

**Closures handed to Apple frameworks must not inherit `@MainActor` isolation.** This is the single biggest source of crashes here. Under Swift 6 an isolation-inheriting closure gets an executor assertion; when the framework calls it on its own queue, `dispatch_assert_queue` trips and the process takes `SIGTRAP`.

Confirmed offenders, all fixed — do not reintroduce the pattern:
- `MPMediaItemArtwork(boundsSize:requestHandler:)` — called on MediaPlayer's `*/accessQueue`. Must be `@Sendable`. This crashed the app on every track that had cover art.
- `AVPlayerItem.observe(\.status)` — KVO fires on an arbitrary AVFoundation queue. Read values there, then hop with `Task { @MainActor in }`. `MainActor.assumeIsolated` traps here.
- `MPRemoteCommandCenter` handlers — no documented queue. Hop explicitly.

`MainActor.assumeIsolated` is only safe when the API documents delivery on the main queue (`addPeriodicTimeObserver(forInterval:queue: .main)`, `NotificationCenter.addObserver(..., queue: .main)`).

**iOS hides an app from the Files app while its `Documents/` is empty.** `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are not enough. Lyra seeds a readme (`AudioFile.prepareDropZone()`) so the folder appears — otherwise the only import route is unreachable. Do not remove that.

**Deleting the app deletes its container, and no app can intercept or be notified.** There is no API. The only real mitigation is external folders, which is why they exist. Never tell the user this can be prevented.

**`AVAsset` decodes FLAC but usually reports no metadata for it.** `FlacTagReader` parses STREAMINFO / VORBIS_COMMENT / PICTURE from the header directly. Vorbis comment lengths are **little-endian** — the one place FLAC is not big-endian.

**Do not persist artwork in the database.** `ArtworkCache` keys by SHA-256 of the source bytes, so an album stores one JPEG rather than one per track, and it lives in `Caches/` where iOS can reclaim it.

**Do not present a `.sheet` from a deeply nested view.** Sheets attached inside `ContentUnavailableView` actions or `tabViewBottomAccessory` silently fail to present. Hoist presentation state up (`PlayerController.isNowPlayingPresented`, `LibraryView.showingSources`) and attach the sheet near the navigation root.

## Verifying changes

Unit tests cover the logic worth covering: tag parsing, the FLAC reader (against headers synthesised in-test, no binary fixtures), path round-tripping, scan grouping, playlist ordering, and the full queue/shuffle/repeat state machine via `FakeEngine`.

For anything touching playback or the library, also run it in the simulator with a real tagged file. `say -o x.aiff …` plus `ffmpeg`/`flac` generates test audio; drop it into the app container found via `xcrun simctl get_app_container "iPhone 17" care.davinci.lyra data`.

**Simulator caveat:** driving the UI with AppleScript `click at` is unreliable — clicks in the lower half of the window often do not land, and SwiftUI `Menu` items cannot be driven at all. Do not conclude a button is broken from a synthetic click alone, and do not claim a flow works because a click appeared to succeed. Say what was actually verified.

**Cannot be verified off-device at all:** background audio while locked, lock-screen transport, interruption/resume on a call, and the document picker. Flag these as untested rather than assuming.

## Conventions

- Comments explain *why*, never *what*. Most existing comments record a constraint or a bug that is not visible in the code — keep that bar.
- Swift Testing (`@Test`, `#expect`), not XCTest. Test names are sentences describing the behaviour.
- Commit messages: what changed and the reasoning behind it, wrapped at ~72 columns. Explain the constraint that forced the design.
- User-facing copy is plain and specific. The empty state reports what the scan actually saw rather than a generic message, because a sideloaded app has no console to check.
