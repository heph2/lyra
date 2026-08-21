# Roadmap

Goal: make a normal folder full of music feel like a synchronised personal library, while the files stay under the user's control.

---

## Phase 1 — Folder libraries · done

Shipped in `005edfb`. Native folder picker, security-scoped bookmarks refreshed when stale, recursive scan across sources, cheap diff (path + size + mtime, no hashing), metadata and artwork extraction, per-source folder browsing, playback resolving source → URL before reaching the player.

Two behaviours worth remembering: track identity is source-qualified so old libraries migrate without a schema change, and an unreachable source is held back from removals so unplugging a drive does not wipe the index.

**Still unverified on device:** the document picker and the Music Folders sheet. The simulator harness cannot drive them. Confirm before building on top.

---

## Phase 2 — WebDAV libraries

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
    func metadataHeader(for item: ScannedFile) async throws -> Data   // ranged read
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

### Done when

A WebDAV library can be added, tested, scanned, and diffed, and its tracks appear in the library as remote-only. No downloading yet.

---

## Phase 3 — Offline sync

Sketch only; detail it when Phase 2 is sound.

Track state: `availableRemote` · `downloading` · `availableOffline` · `modifiedRemote` · `unavailable`. Shown as `☁ / ↓ / ✓`.

Downloads into `Application Support/Libraries/<library-id>/Music/`, preserving relative paths. `URLSession` background download tasks, file-backed so nothing large lands in RAM, atomic replace so a failed download never corrupts a playable copy, cancellable, 2–4 concurrent with the limit configurable later. A modified remote file re-downloads only if it was being kept offline.

Playback resolves to the local copy when present. Streaming is explicitly **not** a goal — only add it if it falls out for free.

---

## Phase 4 — Polish

Sync status UI, automatic rescan when it is actually useful, artwork cache improvements, better errors, background-transfer handling, library management.

---

## Non-goals

Accounts. A backend. Analytics. Apple Music APIs. Streaming as a headline feature. Any dependency that URLSession already covers.
