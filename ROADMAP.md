# Roadmap

Goal: make a normal folder full of music feel like a synchronised personal library, while the files stay under the user's control.

---

## Phase 1 — Folder libraries · done

Shipped in `005edfb`. Native folder picker, security-scoped bookmarks refreshed when stale, recursive scan across sources, cheap diff (path + size + mtime, no hashing), metadata and artwork extraction, per-source folder browsing, playback resolving source → URL before reaching the player.

Two behaviours worth remembering: track identity is source-qualified so old libraries migrate without a schema change, and an unreachable source is held back from removals so unplugging a drive does not wipe the index.

**Still unverified on device:** the document picker behind **Add Library → Local Folder**. `LyraUITests` now drives the Library Sources sheet itself, but not the system picker it presents. Confirm before building on top.

---

## Phase 2 — WebDAV libraries · implemented, device verification pending

Add a remote source type so a folder on a PC, Mac, or NAS can back the library.

```
PC / Mac / NAS → shared folder → WebDAV → Lyra → local offline library
```

Nothing here should require an account, a backend, or a proprietary service.

### 2.0 Lift the source abstraction first

`SourceRegistry` currently assumes every source is a directory on a filesystem it can enumerate with `FileManager`. WebDAV does not fit that, and bolting HTTP onto it would produce two tangled implementations.

Split responsibilities:

```swift
protocol LibrarySource {
    var id: String { get }
    var displayName: String { get }
    func scan() async throws -> [ScannedFile]
}

protocol RemoteLibrarySource: LibrarySource {
    // Ranged read. `maxBytes` is the caller's budget: indexing a remote library
    // means paying for every byte, so the scanner asks for the smallest prefix.
    func metadataHeader(for item: ScannedFile, maxBytes: Int) async throws -> Data
    func download(_ item: ScannedFile, to destination: URL) async throws
}
```

- `LocalFolderSource` — today's bookmark + `FileManager` walk, moved behind the protocol. Drop zone is just a `LocalFolderSource` with a fixed id.
- `WebDAVSource` — new.
- `LibraryManager` replaces `SourceRegistry` as the thing that owns the source list and hands `LibraryScanner` a uniform list of items.

`ScannedFile` already carries path, size, and mtime — the three fields the diff needs — so the scanner and `LibraryStore.planScan()` should need little change. That is the test of whether the abstraction is right: **if Phase 2 forces changes to the diff logic, the split is wrong.**

Do this refactor on its own, with the existing tests green, before writing any HTTP.

### 2.1 Credentials

- `KeychainStore` wrapping `SecItem*`, keyed by library id. Password only.
- Non-secret config (name, URL, username) can stay alongside the other source metadata. **Never** put the password in `UserDefaults`.
- Deleting a library must delete its Keychain item.
- Handle credentials changing under us: a 401 on scan should surface as "sign in again", not as an empty library.

### 2.2 WebDAV client

`URLSession` + async/await. No dependency — WebDAV is a small amount of XML over HTTP and a library would not earn its weight.

- `PROPFIND` with `Depth: 1`, walked recursively. Request only the properties needed: `getcontentlength`, `getlastmodified`, `resourcetype`, `displayname`.
- Parse with `XMLParser`. Namespaces vary between servers (`D:`, `d:`, unprefixed) — match on local name, not prefix.
- `GET` for downloads, `HEAD` where a cheap freshness check helps.
- Isolate every HTTP detail inside `WebDAVSource`; nothing above it should know the protocol exists.

Percent-encoding is the likeliest source of bugs. Server hrefs come back encoded and may be absolute or relative. Normalise to a path relative to the library root before it reaches the index, and keep the encoded form only for building requests.

### 2.3 Remote indexing

Reuse the existing diff. Remote items produce the same `ScannedFile` values, so new / modified / unchanged / removed classification is unchanged.

Metadata is the one genuinely new problem: tags live inside files that are not on the device yet.

- Prefer a **ranged `GET`** of the first ~1 MB to read tags without pulling the whole track. ID3v2 and FLAC both put their metadata at the head of the file. Existing `MetadataReader` / `FlacTagReader` can parse from that buffer.
- MP4/M4A is the awkward case: `moov` is sometimes at the end. Fall back to filename- and path-derived metadata until the file is downloaded, then re-read.
- **Confirm the ranged-read behaviour against a real server before relying on it** — not every WebDAV server honours `Range`. If a server does not, degrade to path-derived metadata rather than downloading everything.

### 2.4 UI

Rename the existing sheet to **Library Sources** and add a type picker:

```
Library Sources

  On My iPhone        Local folder    ✓ Available
  Home Server         WebDAV          ✓ Connected

  + Add Library
```

```
Add Library
  Local Folder
  WebDAV Server
```

WebDAV form: name, URL, username, password, **Test Connection**, Add. Test Connection issues a `PROPFIND` against the root and reports precisely — unreachable host, bad credentials, not a WebDAV server, and success with a file count are four different messages.

Keep it plain. No wizard.

### 2.5 Tests

The sync engine must be testable without a server. Inject a `URLProtocol` stub and drive it with canned `207 Multi-Status` bodies.

Fixtures should cover: nested directories; spaces, Unicode, apostrophes, `#`, `%`, `?` in names; duplicate filenames in different folders; the namespace-prefix variants; a server returning absolute vs relative hrefs; an empty collection; a malformed body.

Plus diff cases against the index — added, removed, modified, unchanged — which are already covered for local sources and should pass unchanged through `WebDAVSource`.

### Current status

A WebDAV library can be added, tested, recursively scanned, and diffed. Remote tracks are written to the library immediately from the inventory while bounded ranged reads enrich their metadata. Credentials are stored in the Keychain and source failures are held back from removals.

The protocol and scan logic have unit coverage against stubbed `URLProtocol` responses and a real server has returned the expected nested inventory. Physical-device launch and full-library indexing remain the release gate after concurrent source enumeration exposed Swift runtime crashes; source scans are now deliberately sequential.

---

## Phase 3 — Offline sync · in progress

Selective track and album downloads are implemented. Copies are file-backed under `Application Support/Libraries/<library-id>/Music/`, preserve relative paths, use atomic replacement, and remain selected across rescans so modified remote files are downloaded again.

Track state: `availableRemote` · `downloading` · `availableOffline` · `modifiedRemote` · `unavailable`. Shown in the track row as a cloud, a spinner, a green filled checkmark, a refresh arrow, and a warning triangle — each with its own accessibility label.

The remaining transfer work is background `URLSession` support so an in-progress download can survive suspension. Current downloads are file-backed and bounded to three concurrent transfers, but run in the app's foreground session.

Playback resolves to the local copy when present. Phase 3.5 adds on-demand network playback for remote-only tracks without changing offline selection or retaining streamed files.

---

## Phase 3.5 — WebDAV streaming · planned

Play an indexed WebDAV track without first keeping a complete copy on the device. Offline selection remains explicit and always wins: if a valid offline copy exists, playback must use it and perform no network request.

This is authenticated progressive playback, not a general streaming service. Lyra still has no account or backend, does not transcode, and does not silently turn streamed tracks into offline copies.

### 3.5.0 Prove the server contract

Streaming requires reliable byte ranges. Before changing playback, extend the mock WebDAV server and test the real server for:

- `GET` with `Range: bytes=<start>-<end>` returns `206 Partial Content`.
- `Content-Range` identifies the requested interval and total file length.
- Non-zero ranges work; a server that only honours `bytes=0-...` is insufficient for seeking and formats whose metadata lives near the end.
- `416 Range Not Satisfiable`, short reads, disconnects, and a file changing during playback are distinguishable failures.
- Redirects cannot carry Basic credentials away from the configured scheme, host, and effective port.

A server that ignores `Range` must remain indexable and downloadable, but streaming from it is unavailable. Do not accept a `200` response to a non-zero range and accidentally download the whole file.

### 3.5.1 Introduce a playback resource boundary

`Track.fileURL` and `PlaybackEngine.load(url:autoplay:)` encode the current local-only assumption. Replace that boundary with a source-neutral value:

```swift
enum PlaybackResource: Sendable {
    case local(URL)
    case remote(RemotePlaybackResource)
}

struct RemotePlaybackResource: Sendable {
    let sourceID: String
    let relativePath: String
    let contentLength: Int64
    let fileExtension: String
}
```

Add one resolver with an explicit order:

1. A valid offline copy.
2. A local-folder URL.
3. A WebDAV resource descriptor when the source and credentials exist.
4. No resource, with the existing unreachable-track error path.

The descriptor contains stable identity and non-secret metadata only. It must not contain a password, an Authorization header, or a credential-bearing URL. Queue, shuffle, repeat, Now Playing, and playlist code continue to operate on `Track`; only the final load boundary changes.

### 3.5.2 Add authenticated range reads to `WebDAVSource`

Extend `RemoteLibrarySource` with a cancellable byte-range operation used by playback. Keep URL construction, Basic authentication, redirect/origin checks, and HTTP status mapping inside `WebDAVSource`.

The response must expose:

- validated start/end offsets and total content length;
- a content type derived safely from the file extension when the server sends a generic or missing MIME type;
- incremental body chunks, not one `Data` containing the requested range;
- cancellation that immediately cancels the underlying `URLSessionTask`.

Use an ephemeral playback `URLSession` with `urlCache = nil` and a request cache policy that ignores local caches. Streaming may buffer in memory as AVFoundation requires, but it must not create a persistent music file or grow `Application Support/Libraries`. Only `OfflineSyncManager` may create an offline copy.

### 3.5.3 Bridge AVFoundation through a resource loader

Create a `WebDAVAssetLoader` that owns an `AVURLAsset` with an internal custom URL scheme and implements `AVAssetResourceLoaderDelegate`. AVFoundation reports the byte offset and length it needs through `AVAssetResourceLoadingDataRequest`; feed those bytes incrementally from the authenticated WebDAV range operation and fill `AVAssetResourceLoadingContentInformationRequest` with length, type, and byte-range support. Apple documents this as the supported boundary for application-provided asset data: [AVAssetResourceLoaderDelegate](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate) and [AVAssetResourceLoadingDataRequest](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingdatarequest).

Hard requirements:

- Retain the loader for exactly as long as its `AVPlayerItem`; replacing or stopping the item cancels every outstanding range task.
- Use a dedicated serial delegate queue. AVFoundation callbacks do not inherit `@MainActor`; read request values there and hop explicitly when actor-isolated state is needed.
- Key active requests by loading-request identity so cancellation cannot terminate a newer request for the same track.
- Bound concurrent range requests and forward response chunks directly to AVFoundation instead of accumulating an entire track or large seek range.
- Never log the custom URL, original server URL, path, username, password, or Authorization value. Diagnostics may record source type, status code, requested byte count, bytes delivered, cancellation, and time to first audio.

Update `AVPlayerEngine` to load either a plain local `AVURLAsset` or the asset/loader pair. Keep the loader generation token beside the existing playback load token so callbacks from a replaced remote item cannot mutate the new item.

### 3.5.4 Playback and UI behaviour

- Tapping a remote-only track streams immediately; it does not select the track for offline use.
- The cloud/offline controls keep their current meaning and remain the only way to retain a full local copy.
- Show buffering in the player surfaces using a normal inline `ProgressView`, without a modal or opaque square. Stable player dimensions must not shift as buffering starts and stops.
- Pause preserves the current buffered position. Stop, changing tracks, or removing the source cancels network work.
- Seeking issues a new range request and cancels obsolete ranges.
- A `401` reports that the library needs sign-in. No range support reports that this server requires downloading first. Connectivity loss reports a retryable playback failure and lets the existing queue skip policy advance without looping.
- A modified remote file detected by rescan invalidates active playback on the next load; it must not overwrite an existing offline copy except through offline reconciliation.

Do not add automatic prefetch of the next track initially. Measure track-start latency and server behaviour first; prefetch adds credential-bearing requests, cancellation state, and cellular usage before it proves a user benefit.

### 3.5.5 Tests and release gates

Unit tests with `URLProtocol` fixtures:

- resolver priority: offline, local, remote, unavailable;
- `206` parsing and `Content-Range` validation;
- servers returning `200`, malformed ranges, `401`, `404`, `416`, redirects, short bodies, and disconnects;
- request cancellation on seek, next, stop, and stale load-token callbacks;
- no cross-origin credential forwarding and no credential/path data in diagnostics;
- queue, shuffle, repeat, and unplayable-track limits remain unchanged for remote failures.

Simulator integration test with the logging mock WebDAV server:

- playback starts before the full file transfers;
- a seek produces a non-zero range;
- next/stop cancels outstanding work;
- a streamed track creates no file under `Application Support/Libraries`;
- an offline-selected track plays with the server stopped and performs no request;
- byte accounting proves playback did not fetch unrelated tracks or albums.

Physical-device release gate:

- SideStore-signed build against the real WebDAV server;
- locked-screen and background playback for at least one full remote album;
- interruption/resume, route changes, Wi-Fi loss/recovery, and a cellular connection;
- long FLAC/WAV files, MP3, M4A with `moov` at the end, seeking near EOF, and Unicode paths;
- memory stays bounded during an hour-long lossless stream and device storage does not grow by the streamed file size.

### Acceptance criteria

- Any indexed track on a range-capable WebDAV source can start without a prior offline download.
- Offline copies are always preferred and remain playable in Airplane Mode.
- Streaming one track never downloads the rest of its album and never persists a full copy.
- Credentials stay in the Keychain/WebDAV boundary and are never embedded in asset URLs or diagnostics.
- Seek, next, stop, queue exhaustion, source removal, and network failure terminate their obsolete requests without crashes, hangs, or retry loops.
- Servers without usable range support fail with a specific download-first message.

---

## Phase 4 — Polish · started

Privacy-safe unified logging now covers launch, scans, WebDAV operations, offline transfers, and playback failures. Tagged CI releases build the unsigned IPA, retain dSYMs, and publish a SideStore update source. Remaining work: sync status polish, automatic rescan when it is actually useful, artwork cache improvements, better errors, background-transfer handling, and library management.

---

## Non-goals

Accounts. A backend. Analytics. Apple Music APIs. Radio, HLS catalogs, transcoding, or automatic whole-library caching. Any dependency that URLSession and AVFoundation already cover.
