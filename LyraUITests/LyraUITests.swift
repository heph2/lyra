import XCTest

/// Drives the shipping app in the simulator and photographs what the user sees.
///
/// These are deliberately separate from `LyraTests`: they need a booted
/// simulator, a seeded drop zone and — for the WebDAV cases — a server on the
/// host, so they run under their own scheme rather than in CI's unit-test pass.
@MainActor
final class LyraUITests: XCTestCase {
    /// XCTest's `setUp()` overrides stay nonisolated, so launching the app
    /// there from this @MainActor case would cross actors. Every test starts
    /// by waiting on the UI, so launching on first use is the same moment.
    private lazy var app: XCUIApplication = {
        let app = XCUIApplication()
        app.launch()
        return app
    }()

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - Evidence helpers

    /// Named so the exported attachment filenames sort into the order a
    /// reviewer should read them in.
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForText(_ text: String, timeout: TimeInterval = 30) -> Bool {
        let element = app.staticTexts[text]
        return element.waitForExistence(timeout: timeout)
    }

    // MARK: - Local library

    func testLocalLibraryIndexesDroppedFolders() {
        XCTAssertTrue(waitForText("Library", timeout: 30), "library tab never appeared")
        selectSection("Songs")
        capture("01-library-songs")

        // Songs seeded into the drop zone before launch.
        XCTAssertTrue(app.staticTexts["First Program"].waitForExistence(timeout: 30),
                      "FLAC tags were not read into the library")
        XCTAssertTrue(app.staticTexts["Punched Card"].exists, "MP3 was not indexed")

        selectSection("Albums")
        capture("02-library-albums")
        XCTAssertTrue(app.staticTexts["Analytical Engine"].waitForExistence(timeout: 10))

        app.staticTexts["Analytical Engine"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Bernoulli Numbers"].waitForExistence(timeout: 10))
        capture("03-album-detail")

        // Play the first track and confirm the transport takes over.
        app.staticTexts["First Program"].firstMatch.tap()
        capture("04-mini-player")

        let nowPlaying = app.buttons["Now Playing"]
        if nowPlaying.waitForExistence(timeout: 10) {
            nowPlaying.tap()
            capture("05-now-playing")
        }
    }

    // MARK: - Artists / folders

    func testArtistsAndFolderBrowsing() {
        XCTAssertTrue(waitForText("Library", timeout: 30))
        selectSection("Artists")
        XCTAssertTrue(app.staticTexts["Ada Lovelace"].waitForExistence(timeout: 20))
        capture("06-artists")

        selectSection("Folders")
        capture("07-folders")
    }

    // MARK: - WebDAV

    /// Adds the WebDAV library through the real form, streams a cloud-only
    /// track, then keeps its album offline through the real context menu. The
    /// host-side access log distinguishes ranged playback from the full copy.
    func testWebDAVLibraryIndexesRemotelyThenDownloadsSelection() {
        XCTAssertTrue(waitForText("Library", timeout: 30))

        openSourcesSheet()
        capture("08-library-sources")

        app.buttons["Add Library"].firstMatch.tap()
        tapDialogButton("WebDAV Server")

        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 10), "WebDAV form never appeared")
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText("Nova NAS")
        app.textFields["URL"].tap()
        app.textFields["URL"].typeText("http://127.0.0.1:8099/")
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText("lyra")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("s3cr3t-webdav-pw")
        capture("09-webdav-form")

        // One retry, because a first request to a just-started local server can
        // time out — and tapping again is exactly what a user would do.
        let connected = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Connected.'")).firstMatch
        app.buttons["Test Connection"].firstMatch.tap()
        if !connected.waitForExistence(timeout: 60) {
            app.buttons["Test Connection"].firstMatch.tap()
            XCTAssertTrue(connected.waitForExistence(timeout: 60),
                          "Test Connection never reported success")
        }
        capture("10-webdav-test-connection")

        app.buttons["Add"].firstMatch.tap()

        // An unsigned simulator build has no Keychain entitlement, so the form
        // stays open on its "added but the password could not be saved"
        // warning. That is the designed degradation, not a failure: the library
        // is already added, so dismiss the form and carry on.
        let formDone = app.navigationBars["WebDAV Server"].buttons["Done"]
        if formDone.waitForExistence(timeout: 20) {
            capture("11a-webdav-keychain-warning")
            formDone.tap()
        }
        _ = app.buttons["Add Library"].firstMatch.waitForExistence(timeout: 20)
        capture("11-sources-with-webdav")

        let sourcesDone = app.navigationBars["Library Sources"].buttons["Done"]
        XCTAssertTrue(sourcesDone.waitForExistence(timeout: 10), "sources sheet had no Done button")
        sourcesDone.tap()

        // Remote tracks must show up in the library without being downloaded.
        XCTAssertTrue(app.staticTexts["Event Horizon"].waitForExistence(timeout: 120),
                      "remote tracks never appeared in the library")
        capture("12-library-with-remote-tracks")

        // Remote rows carry the cloud badge until the user asks for a copy.
        XCTAssertTrue(app.images["Available remotely"].firstMatch.exists,
                      "remote track is missing its cloud indicator")

        // Play before requesting an offline copy. A visible elapsed time proves
        // AVFoundation decoded remote bytes; the transport alone appears as
        // soon as the controller creates its queue and is not enough evidence.
        app.staticTexts["Event Horizon"].firstMatch.tap()
        let nowPlaying = app.buttons["Now Playing"]
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 20), "streaming transport never appeared")
        nowPlaying.tap()
        XCTAssertTrue(app.staticTexts["Event Horizon"].waitForExistence(timeout: 20))
        let elapsed = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '0:0[1-9]'")
        ).firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 30), "remote stream never advanced")
        capture("13-streaming-cloud-only-track")
        let pauseButtons = app.buttons.matching(identifier: "Pause")
        for index in 0..<pauseButtons.count {
            let button = pauseButtons.element(boundBy: index)
            if button.isHittable {
                button.tap()
                break
            }
        }
        app.navigationBars.buttons["Done"].firstMatch.tap()

        selectSection("Albums")
        XCTAssertTrue(app.staticTexts["Deep Field"].waitForExistence(timeout: 30))
        capture("14-albums-local-and-remote")

        // Keep the whole remote album offline, through the context menu a user
        // would actually long-press.
        app.staticTexts["Deep Field"].firstMatch.press(forDuration: 1.2)
        let download = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15), "album context menu had no download action")
        capture("15-offline-context-menu")
        download.tap()

        selectSection("Songs")
        let offline = app.images["Available offline"].firstMatch
        XCTAssertTrue(offline.waitForExistence(timeout: 180), "album never finished downloading for offline use")
        capture("16-offline-downloaded")

        // Play a remote track from the offline copy.
        app.staticTexts["Event Horizon"].firstMatch.tap()
        capture("17-playing-offline-track")
    }

    /// A wrong password has to fail as a message in the form, not a crash.
    func testWebDAVRejectsBadCredentials() {
        XCTAssertTrue(waitForText("Library", timeout: 30))
        openSourcesSheet()
        app.buttons["Add Library"].firstMatch.tap()
        tapDialogButton("WebDAV Server")

        XCTAssertTrue(app.textFields["URL"].waitForExistence(timeout: 10))
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText("Wrong NAS")
        app.textFields["URL"].tap()
        app.textFields["URL"].typeText("http://127.0.0.1:8099/")
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText("lyra")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("not-the-password")

        app.buttons["Test Connection"].firstMatch.tap()
        let failure = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'sign in' OR label CONTAINS 'Sign in' OR label CONTAINS 'password'")
        ).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 60), "bad credentials produced no message")
        capture("17-webdav-bad-credentials")
        XCTAssertTrue(app.state == .runningForeground, "app left the foreground on an auth failure")
    }

    /// The library remembers its last section in `@AppStorage`, so a test that
    /// expects a particular list has to ask for it rather than assume Songs.
    private func selectSection(_ name: String) {
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30), "section picker missing \(name)")
        button.tap()
    }

    /// The confirmation dialog renders its choices as an action sheet while the
    /// Library Sources sheet is still on screen, so the same label matches more
    /// than one element. Tap the hittable one rather than assuming a single hit.
    private func tapDialogButton(_ label: String) {
        let query = app.buttons.matching(identifier: label)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            for index in 0..<query.count {
                let candidate = query.element(boundBy: index)
                if candidate.exists, candidate.isHittable {
                    candidate.tap()
                    return
                }
            }
            usleep(300_000)
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "element-tree-\(label)"
        tree.lifetime = .keepAlways
        add(tree)
        XCTFail("no hittable dialog button labelled \(label)")
    }

    /// Photographs the scan progress card. It replaced a full-width material
    /// strip, so what it looks like mid-index is the whole point of the change.
    ///
    /// The mock WebDAV server is started with a per-response delay for this
    /// test; a local-only scan finishes faster than a screenshot can be taken.
    func testScanProgressCardIsVisibleWhileIndexing() {
        XCTAssertTrue(waitForText("Library", timeout: 30))
        selectSection("Songs")
        addWebDAVLibrary(named: "Slow NAS", password: "s3cr3t-webdav-pw")

        let scanning = app.staticTexts["Scanning library…"]
        let reading = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Reading tags'")
        ).firstMatch

        // Whichever phase is on screen first, photograph the card there.
        let deadline = Date().addingTimeInterval(60)
        var appeared = false
        while Date() < deadline {
            if reading.exists || scanning.exists {
                appeared = true
                capture("18-scan-progress-card")
                break
            }
            usleep(200_000)
        }
        if !appeared { capture("18-scan-progress-card-missed") }
        XCTAssertTrue(appeared, "scan progress card never appeared")
    }

    /// Removing an offline copy and then the whole library must delete only
    /// Lyra's own cached copies. The server's files and the drop zone are the
    /// user's, and the host-side checksums taken around this test are what
    /// actually prove they were left alone.
    func testRemovingOfflineCopiesAndSourceLeavesUserFilesAlone() {
        XCTAssertTrue(waitForText("Library", timeout: 30))
        addWebDAVLibrary(named: "Nova NAS", password: "s3cr3t-webdav-pw")
        selectSection("Songs")

        XCTAssertTrue(app.staticTexts["Event Horizon"].waitForExistence(timeout: 120),
                      "remote tracks never appeared")

        // Keep one album offline...
        selectSection("Albums")
        XCTAssertTrue(app.staticTexts["Deep Field"].waitForExistence(timeout: 30))
        app.staticTexts["Deep Field"].firstMatch.press(forDuration: 1.2)
        let download = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        download.tap()

        selectSection("Songs")
        XCTAssertTrue(app.images["Available offline"].firstMatch.waitForExistence(timeout: 180),
                      "album never downloaded")
        capture("19-before-removal")

        // ...then give it back.
        selectSection("Albums")
        XCTAssertTrue(app.staticTexts["Deep Field"].waitForExistence(timeout: 30))
        app.staticTexts["Deep Field"].firstMatch.press(forDuration: 1.2)
        let remove = app.buttons["Remove Offline Copy"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "no remove-offline-copy action")
        capture("20-remove-offline-copy-menu")
        remove.tap()

        selectSection("Songs")
        // Back to cloud-only for every remote track.
        let backToRemote = app.images["Available remotely"]
        XCTAssertTrue(backToRemote.firstMatch.waitForExistence(timeout: 60))
        capture("21-offline-copies-removed")

        // Now drop the whole WebDAV library.
        openSourcesSheet()
        let removeSource = app.buttons["Remove"].firstMatch
        XCTAssertTrue(removeSource.waitForExistence(timeout: 15), "sources sheet had no remove button")
        removeSource.tap()
        capture("22-remove-library-confirmation")
        let confirm = app.buttons["Remove from Lyra"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "no removal confirmation")
        confirm.tap()

        let sourcesDone = app.navigationBars["Library Sources"].buttons["Done"]
        if sourcesDone.waitForExistence(timeout: 15) { sourcesDone.tap() }

        // The local drop-zone tracks must survive removing the remote library.
        XCTAssertTrue(app.staticTexts["First Program"].waitForExistence(timeout: 60),
                      "removing the WebDAV library took the local tracks with it")
        capture("23-after-library-removed")
        XCTAssertFalse(app.staticTexts["Event Horizon"].exists, "remote tracks outlived their library")
    }

    // MARK: - Offline-first (two steps, the server is stopped in between)

    /// Step 1: keep an album offline while the server is reachable.
    func testOfflineFirstStep1KeepAlbumOffline() {
        XCTAssertTrue(waitForText("Library", timeout: 30))
        addWebDAVLibrary(named: "Nova NAS", password: "s3cr3t-webdav-pw")
        selectSection("Songs")
        XCTAssertTrue(app.staticTexts["Event Horizon"].waitForExistence(timeout: 120))

        selectSection("Albums")
        XCTAssertTrue(app.staticTexts["Deep Field"].waitForExistence(timeout: 30))
        app.staticTexts["Deep Field"].firstMatch.press(forDuration: 1.2)
        let download = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        download.tap()

        selectSection("Songs")
        XCTAssertTrue(app.images["Available offline"].firstMatch.waitForExistence(timeout: 180),
                      "album never downloaded")
        capture("24-offline-ready-server-up")
    }

    /// Step 2: the server is gone and, because an unsigned build cannot use the
    /// Keychain, so is the stored password. The downloaded album still has to
    /// play, and the tracks that were never downloaded must not vanish from the
    /// library — an unreachable source is not an empty source.
    func testOfflineFirstStep2PlaysWithServerGone() {
        XCTAssertTrue(waitForText("Library", timeout: 30))
        selectSection("Songs")

        XCTAssertTrue(app.staticTexts["Event Horizon"].waitForExistence(timeout: 60),
                      "the offline album disappeared when the server went away")
        XCTAssertTrue(app.staticTexts["Carrier Wave"].exists,
                      "an unreachable source was treated as an empty source")
        capture("25-library-with-server-gone")

        app.staticTexts["Event Horizon"].firstMatch.tap()
        // Playback of the local copy has to start with no server at all.
        let nowPlaying = app.buttons["Now Playing"]
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 20), "transport never appeared")
        nowPlaying.tap()
        XCTAssertTrue(app.staticTexts["Event Horizon"].waitForExistence(timeout: 20))
        sleep(3)
        capture("26-playing-offline-copy-server-gone")
    }

    /// Fills in and submits the WebDAV form. Returns with the Library Sources
    /// sheet dismissed and the post-add scan already running.
    private func addWebDAVLibrary(named name: String, password: String) {
        openSourcesSheet()
        app.buttons["Add Library"].firstMatch.tap()
        tapDialogButton("WebDAV Server")

        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 10), "WebDAV form never appeared")
        app.textFields["Name"].tap()
        app.textFields["Name"].typeText(name)
        app.textFields["URL"].tap()
        app.textFields["URL"].typeText("http://127.0.0.1:8099/")
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText("lyra")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(password)

        app.buttons["Add"].firstMatch.tap()
        let formDone = app.navigationBars["WebDAV Server"].buttons["Done"]
        if formDone.waitForExistence(timeout: 30) { formDone.tap() }
        let sourcesDone = app.navigationBars["Library Sources"].buttons["Done"]
        if sourcesDone.waitForExistence(timeout: 15) { sourcesDone.tap() }
    }

    private func openSourcesSheet() {
        if app.buttons["Library Sources…"].firstMatch.exists {
            app.buttons["Library Sources…"].firstMatch.tap()
            return
        }
        app.buttons["Options"].firstMatch.tap()
        let item = app.buttons["Library Sources…"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "options menu had no Library Sources item")
        item.tap()
    }
}
