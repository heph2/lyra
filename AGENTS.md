# Working on Lyra

Offline-first iOS music player. No accounts, no subscriptions, no analytics, no App Store. The only network code is the WebDAV client. Sideloaded as an unsigned `.ipa` via SideStore.

Read this before changing anything. Most of it was learned by breaking the app.

---

## Hard constraints

These are not preferences. Violating them breaks the product or the build.

- **Network code stays inside `WebDAVSource`.** `grep -rE "URLSession|dataTask|CFNetwork" Lyra` must only hit `Lyra/Model/WebDAVSource.swift` (plus the odd explanatory comment elsewhere). Nothing above it may know HTTP exists, and everything except remote indexing, remote streaming, and offline downloads has to work fully in Airplane Mode.
- **Diagnostics are local and privacy-safe.** `LyraLog` writes unified logs for Console only — no analytics, no backend. Passwords, server URLs, source names, and track paths must never reach a log line; log structural facts and `DiagnosticValue.errorCode(_:)` instead.
- **No third-party dependencies.** Apple frameworks only: AVFoundation, SwiftUI, SwiftData, MediaPlayer, CryptoKit, ImageIO, OSLog, Security (Keychain), UniformTypeIdentifiers, UIKit, Combine, Foundation. Nothing else.
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
                                     # RELEASE_VERSION=1.2.0 BUILD_NUMBER=7 override the
                                     # version stamped into the archive; CI sets both
bash scripts/uitest/run-ui-tests.sh  # end-to-end UI suite, LyraUITests scheme
swift scripts/make-icon.swift        # lyra-logo.png -> AppIcon.png
```

`Lyra.xcodeproj` is generated and gitignored. `project.yml` is the source of truth. **A new `.swift` file that is not in the project fails with `cannot find 'X' in scope` — run `xcodegen generate` before believing a "missing type" error.**

## Layout

```
project.yml              XcodeGen spec (Lyra, LyraTests, LyraUITests targets/schemes)
lyra-logo.png            icon source art
scripts/                 build-ipa.sh, make-icon.swift, make-sidestore-source.swift
scripts/uitest/          run-ui-tests.sh, make-test-media.sh,
                         mock-webdav-server.py, collect-screenshots.py
.github/workflows/       ipa.yml (test, package, publish the SideStore source)
Lyra/App/                LyraApp (entry, ModelContainer), RootView (tabs, sheets)
Lyra/Diagnostics/        LyraLog categories, DiagnosticValue redaction helpers
Lyra/Model/              Track, Playlist, MusicSource/LibraryManager,
                         LibrarySource + RemoteLibrarySource protocols, WebDAVSource,
                         KeychainStore, OfflineSyncManager/OfflineLibrary,
                         LibraryStore (@ModelActor), LibraryScanner, LibraryGrouping, AudioFile
Lyra/Metadata/           MetadataReader, FlacTagReader, ArtworkCache, TrackMetadata
Lyra/Playback/           PlaybackEngine (protocol + AVPlayer), PlayerController,
                         AudioSessionManager, NowPlayingCenter
Lyra/UI/                 SwiftUI views
LyraTests/               Swift Testing (not XCTest)
LyraUITests/             XCUITest end-to-end suite (XCTest — XCUIApplication requires it)
```

## Invariants

**Track identity is a source-qualified path, never an absolute URL.** The app container UUID changes on every reinstall, so a stored absolute URL is garbage tomorrow. Drop-zone tracks keep a bare relative path (`Artist/Album/01 Song.flac`); external-folder tracks are prefixed `@<source-id>/`. A real relative path never starts with `@`, so they cannot collide. Use `AudioFile.trackPath(sourceID:innerPath:)` / `AudioFile.split(trackPath:)` — never string-munge it by hand.

Keeping drop-zone paths bare is deliberate: it means libraries and playlists written before external folders existed still load, with no SwiftData migration.

**Playlists store paths, not SwiftData relationships.** The path is already stable identity. `Playlist.resolveTracks(in:)` drops paths whose files are gone.

**An unreachable source is not an empty source.** `planScan()` holds back removals for sources that failed to resolve. Without this, unplugging a drive marks every track deleted and guts every playlist referencing them.

**The SwiftData store lives in Application Support, not `Documents/`.** `Documents/` is the user's drop zone, visible in the Files app, and must contain only their music. Application Support **does not exist in a fresh container** — `LyraApp.makeContainer()` creates it explicitly, or the store silently fails open into memory and the library evaporates every launch.

**All SwiftData mutation happens in `LibraryStore`, a `@ModelActor`.** Tag parsing — the expensive part — runs in a bounded `TaskGroup` in `LibraryScanner`, off the model actor.

**A remote library is indexed, not downloaded.** `WebDAVSource` walks the server with `PROPFIND` and writes tracks straight from that inventory; tags come from a bounded ranged `GET` of the front of each file (`metadataHeader(for:maxBytes:)`). A server that ignores `Range` degrades to path-derived metadata — it must never trigger a whole-library download.

**Remote playback streams bounded ranges, it never lands a file.** `WebDAVAssetLoader` answers AVFoundation's resource-loading requests from `readRange(for:range:)`, a chunk at a time, over the same validated same-origin `Range` requests indexing uses. An offline copy always wins over a stream, and a server that refuses ranges must surface "download it" rather than fall back to pulling the whole file.

**Offline copies are Lyra's, source files are the user's.** Downloads live under `Application Support/Libraries/<library-id>/Music/`, mirroring the remote relative path, and `OfflineLibrary` may delete them freely. Removing an offline copy or a WebDAV source must never issue a write to the server.

**WebDAV passwords live only in `KeychainStore`.** `MusicSource` persists name, URL, and username; the password never goes into `UserDefaults` or the SwiftData store. Deleting a library deletes its Keychain item, and a Keychain that is unusable (an unsigned simulator build has no Keychain entitlement) must degrade, not fail the operation.

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

**A simulator destination by name picks `OS=latest`, and the newest runtime may not have that device.** `-destination 'platform=iOS Simulator,name=iPhone 16e'` failed on the `macos-26` runner because that image carried iPhone 16e only on iOS 26.2 while its latest runtime, iOS 26.5, offered iPhone 17. Which device exists on which runtime drifts with every runner image, so CI does not name one: the **Select iOS simulator** step in `ipa.yml` reads `xcrun simctl list devices available --json`, takes the highest iOS runtime that has an available iPhone, and passes that device's **UDID** as `-destination "platform=iOS Simulator,id=$SIMULATOR_UDID"`. Do not "simplify" it back to a device name. Locally a name is fine — you know what is installed.

## Verifying changes

Unit tests cover the logic worth covering: tag parsing, the FLAC reader (against headers synthesised in-test, no binary fixtures), path round-tripping, scan grouping, playlist ordering, the WebDAV client and its scan diff (against stubbed `URLProtocol` responses, no server), offline download bookkeeping, and the full queue/shuffle/repeat state machine via `FakeEngine`.

For anything touching playback or the library, also run it in the simulator with a real tagged file. `say -o x.aiff …` plus `ffmpeg`/`flac` generates test audio; drop it into the app container found via `xcrun simctl get_app_container "iPhone 17" care.davinci.lyra data`.

There is also an end-to-end UI suite, `LyraUITests`, under its own
`LyraUITests` scheme, so the `Lyra` scheme CI runs stays unit-tests-only:

```bash
bash scripts/uitest/run-ui-tests.sh    # screenshots -> build/uitest-evidence/
```

It generates tagged audio (`scripts/uitest/make-test-media.sh`), serves a
"remote" library from `scripts/uitest/mock-webdav-server.py` — which logs the
bytes it actually sends, so partial indexing versus a full download is
measurable — and drives the real UI: indexing a folder dropped into the drop
zone, artist and folder browsing, adding a WebDAV library, rejecting bad
credentials, streaming a cloud-only track before any download exists, being
told to download instead when the server ignores `Range`, the scan progress
card mid-index, keeping an album offline, removing the offline copy and the
source without touching the user's files, and playing a downloaded track with
the server stopped. The groups are run separately because they need different
server states — one wants a deliberately slow server, one a server started
with `LYRA_DAV_IGNORE_RANGE=1` so every GET answers whole, the offline-first
pair needs it stopped between its two steps — and each gets a fresh container:
an unsigned simulator build has no Keychain entitlement, so a WebDAV password
never survives a relaunch.

Per-group evidence lands in `build/`: screenshots in `build/uitest-evidence/`,
one `build/webdav-access-*.jsonl` access log per group so a scenario's byte
accounting is not mixed with another's, and `build/uitest-*-offline-cache.txt`
recording what Lyra actually cached before the next group wipes the container.

**Simulator caveat:** driving the UI with AppleScript `click at` is unreliable — clicks in the lower half of the window often do not land, and SwiftUI `Menu` items cannot be driven at all. Use `LyraUITests` instead; XCUITest reaches both. Do not conclude a button is broken from a synthetic click alone, and do not claim a flow works because a click appeared to succeed. Say what was actually verified.

**Cannot be verified off-device at all:** background audio while locked, lock-screen transport, interruption/resume on a call, and the document picker behind **Add Library → Local Folder**. The Library Sources sheet itself is covered by `LyraUITests`; the picker it presents is not. Flag these as untested rather than assuming.

## Conventions

- Comments explain *why*, never *what*. Most existing comments record a constraint or a bug that is not visible in the code — keep that bar.
- Swift Testing (`@Test`, `#expect`), not XCTest, in `LyraTests`. Test names are sentences describing the behaviour.
  `LyraUITests` is the one exception: `XCUIApplication` is XCTest-only, so that target uses `XCTestCase`.
- Commit messages: what changed and the reasoning behind it, wrapped at ~72 columns. Explain the constraint that forced the design.
- User-facing copy is plain and specific. The empty state reports what the scan actually saw rather than a generic message, because a sideloaded app has no console to check.
