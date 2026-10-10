import XCTest
@testable import OpenYoink

@MainActor
final class NowPlayingModuleTests: XCTestCase {
    func testAdapterPayloadParsesWrappedJSON() throws {
        let data = try XCTUnwrap("""
        {"type":"data","payload":{"title":"Track","artist":"Artist","album":"Album","playbackRate":1,"bundleIdentifier":"com.apple.Music"}}
        """.data(using: .utf8))
        XCTAssertEqual(NowPlayingSnapshot.decodeAdapterPayload(data),
                       .init(title: "Track", artist: "Artist", album: "Album",
                             isPlaying: true, sourceName: "com.apple.Music",
                             playbackRate: 1))
    }

    func testAdapterPlayingFieldTakesPrecedence() throws {
        let data = try XCTUnwrap("""
        {"type":"data","payload":{"title":"Paused Track","playing":false,"playbackRate":1}}
        """.data(using: .utf8))
        XCTAssertEqual(NowPlayingSnapshot.decodeAdapterPayload(data)?.isPlaying, false)
    }

    func testMissingOrBlankTitleIsRejected() throws {
        let missing = try XCTUnwrap("{\"artist\":\"A\"}".data(using: .utf8))
        let blank = try XCTUnwrap("{\"title\":\"  \"}".data(using: .utf8))
        XCTAssertNil(NowPlayingSnapshot.decodeAdapterPayload(missing))
        XCTAssertNil(NowPlayingSnapshot.decodeAdapterPayload(blank))
    }

    func testUntitledBrowserSessionUsesPlayerNameAndKeepsControlsMetadata() throws {
        for title in ["", "\"title\":null,", "\"title\":\"  \","] {
            let data = Data("{\(title)\"bundleIdentifier\":\"com.citrolabs.ego.lite\",\"processIdentifier\":1397,\"playing\":true,\"duration\":100,\"elapsedTime\":12}".utf8)
            let snapshot = try XCTUnwrap(NowPlayingSnapshot.decodeAdapterPayload(data) { _ in "ego lite" })
            XCTAssertEqual(snapshot.title, "ego lite")
            XCTAssertTrue(snapshot.isPlaying)
            XCTAssertEqual(snapshot.sourceName, "com.citrolabs.ego.lite")
            XCTAssertEqual(snapshot.duration, 100)
            XCTAssertEqual(snapshot.elapsedTime, 12)
        }
    }

    func testUntitledSessionNeedsAClientAndPlaybackState() throws {
        for payload in ["null", "{}", "{\"playing\":true}",
                        "{\"bundleIdentifier\":\"browser\"}",
                        "{\"processIdentifier\":0,\"playing\":true}"] {
            XCTAssertNil(NowPlayingSnapshot.decodeAdapterPayload(Data(payload.utf8)))
        }
        let pidOnly = Data("{\"processIdentifier\":1397,\"playing\":false}".utf8)
        XCTAssertNotNil(NowPlayingSnapshot.decodeAdapterPayload(pidOnly))
    }

    func testMalformedOutputIsIsolated() {
        XCTAssertNil(NowPlayingSnapshot.decodeAdapterPayload(Data([0xFF, 0x00])))
    }

    func testScrubMathSupportsClickAndDragClamping() {
        XCTAssertEqual(MediaScrubMath.seconds(at: 0, width: 200, duration: 240), 0)
        XCTAssertEqual(MediaScrubMath.seconds(at: 50, width: 200, duration: 240), 60)
        XCTAssertEqual(MediaScrubMath.seconds(at: 250, width: 200, duration: 240), 240)
        XCTAssertEqual(MediaScrubMath.seconds(at: -10, width: 200, duration: 240), 0)
        XCTAssertEqual(MediaScrubMath.seconds(at: 20, width: 0, duration: 240), 0)
    }

    func testScrubMathKeepsThumbCenteredUnderPointer() {
        let width = 532.0
        let inset = 5.0
        let pointerLocation = 329.5
        let seconds = MediaScrubMath.seconds(at: pointerLocation,
                                             width: width,
                                             duration: 223,
                                             horizontalInset: inset)
        XCTAssertEqual(MediaScrubMath.location(for: seconds,
                                               width: width,
                                               duration: 223,
                                               horizontalInset: inset),
                       pointerLocation,
                       accuracy: 0.001)
        XCTAssertEqual(MediaScrubMath.location(for: 0,
                                               width: width,
                                               duration: 223,
                                               horizontalInset: inset), inset)
        XCTAssertEqual(MediaScrubMath.location(for: 223,
                                               width: width,
                                               duration: 223,
                                               horizontalInset: inset), width - inset)
    }

    func testAdapterPayloadParsesArtworkAndTimeline() throws {
        let artwork = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = artwork.base64EncodedString()
        let data = try XCTUnwrap("""
        {"type":"data","payload":{"title":"Track","artworkData":"\(encoded)","duration":245.5,"elapsedTime":61.25,"playbackRate":1}}
        """.data(using: .utf8))
        let snapshot = try XCTUnwrap(NowPlayingSnapshot.decodeAdapterPayload(data))
        XCTAssertEqual(snapshot.artworkData, artwork)
        XCTAssertEqual(snapshot.duration, 245.5)
        XCTAssertEqual(snapshot.elapsedTime, 61.25)
        XCTAssertEqual(snapshot.playbackRate, 1)
    }

    func testProjectedElapsedAdvancesOnlyWhilePlayingAndClamps() throws {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: nil, album: nil,
                               isPlaying: true, sourceName: nil,
                               duration: 100, elapsedTime: 90, playbackRate: 1))
        XCTAssertEqual(store.projectedElapsed(
            at: store.snapshotReceivedAt.addingTimeInterval(20)
        ), 100)

        source.snapshot?(.init(title: "Track", artist: nil, album: nil,
                               isPlaying: false, sourceName: nil,
                               duration: 100, elapsedTime: 42, playbackRate: 0))
        XCTAssertEqual(store.projectedElapsed(
            at: store.snapshotReceivedAt.addingTimeInterval(20)
        ), 42)
    }

    func testSeekClampsTargetAndUpdatesProjectedPosition() async throws {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: "Artist", album: nil,
                               isPlaying: false, sourceName: "Player",
                               duration: 100, elapsedTime: 10))

        let succeeded = await store.seek(to: 140)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(source.commands.last, .seek(to: 100))
        XCTAssertEqual(store.projectedElapsed(), 100)
    }

    func testRepeatedSeekFailureDisablesSeekingForCurrentSource() async {
        let source = FakeSource()
        source.sendResult = false
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: nil, album: nil,
                               isPlaying: true, sourceName: "Player",
                               duration: 100, elapsedTime: 10, playbackRate: 1))

        let firstAttempt = await store.seek(to: 20)
        XCTAssertFalse(firstAttempt)
        XCTAssertTrue(store.supportsSeeking)
        let secondAttempt = await store.seek(to: 30)
        XCTAssertFalse(secondAttempt)
        XCTAssertFalse(store.supportsSeeking)
    }

    func testPendingSeekIgnoresStaleTimelineUntilSourceConverges() async throws {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: "Artist", album: nil,
                               isPlaying: true, sourceName: "Player",
                               duration: 200, elapsedTime: 10, playbackRate: 1))
        let succeeded = await store.seek(to: 80)
        XCTAssertTrue(succeeded)

        source.snapshot?(.init(title: "Track", artist: "Artist", album: nil,
                               isPlaying: true, sourceName: "Player",
                               duration: 200, elapsedTime: 11, playbackRate: 1))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.projectedElapsed()), 79)

        source.snapshot?(.init(title: "Track", artist: "Artist", album: nil,
                               isPlaying: true, sourceName: "Player",
                               duration: 200, elapsedTime: 80.5, playbackRate: 1))
        XCTAssertEqual(try XCTUnwrap(store.snapshot?.elapsedTime), 80.5, accuracy: 0.01)
    }

    func testJSONLineBufferHandlesSplitAndMultipleLines() {
        var buffer = JSONLineBuffer()
        XCTAssertTrue(buffer.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = buffer.append(Data("1}\n{\"b\":2}\npartial".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(buffer.append(Data("-end\n".utf8))
            .map { String(decoding: $0, as: UTF8.self) }, ["partial-end"])
    }

    func testRetryPolicyStopsAfterOneTwoFourSeconds() {
        XCTAssertEqual(AdapterRetryPolicy.delay(afterFailure: 1), .seconds(1))
        XCTAssertEqual(AdapterRetryPolicy.delay(afterFailure: 2), .seconds(2))
        XCTAssertEqual(AdapterRetryPolicy.delay(afterFailure: 3), .seconds(4))
        XCTAssertNil(AdapterRetryPolicy.delay(afterFailure: 4))
    }

    func testPrimaryFailureStartsFallbackWithoutFailingWholeModule() {
        let primary = FakeSource()
        let fallback = FakeSource()
        let source = FallbackNowPlayingSource(primary: primary, fallback: fallback)
        var failed = false
        source.start(onSnapshot: { _ in }, onFailure: { failed = true })
        XCTAssertEqual(primary.startCount, 1)
        primary.fail?()
        XCTAssertEqual(primary.stopCount, 1)
        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertFalse(failed)
        source.stop()
    }

    func testRefreshReachesOnlyTheActiveSource() {
        let primary = FakeSource()
        let fallback = FakeSource()
        let source = FallbackNowPlayingSource(primary: primary, fallback: fallback)
        source.refresh()
        XCTAssertEqual(primary.refreshCount, 0)
        source.start(onSnapshot: { _ in }, onFailure: {})
        source.refresh()
        XCTAssertEqual(primary.refreshCount, 1)
        primary.fail?()
        source.refresh()
        XCTAssertEqual(primary.refreshCount, 1)
        XCTAssertEqual(fallback.refreshCount, 1)
        source.stop()
        source.refresh()
        XCTAssertEqual(fallback.refreshCount, 1)
    }

    func testOldPrimaryCallbacksCannotSwitchOrOverwriteRestartedSource() {
        let primary = FakeSource()
        let fallback = FakeSource()
        let source = FallbackNowPlayingSource(primary: primary, fallback: fallback)
        var title: String?
        source.start(onSnapshot: { title = $0?.title }, onFailure: {})
        let oldSnapshot = primary.snapshot
        let oldFailure = primary.fail
        source.stop()
        source.start(onSnapshot: { title = $0?.title }, onFailure: {})
        primary.snapshot?(.init(title: "new", artist: nil, album: nil, isPlaying: true, sourceName: nil))
        oldSnapshot?(.init(title: "stale", artist: nil, album: nil, isPlaying: true, sourceName: nil))
        oldFailure?()
        XCTAssertEqual(title, "new")
        XCTAssertEqual(fallback.startCount, 0)
        source.stop()
    }

    func testPrimarySnapshotAfterFallbackCannotReplaceCurrentPlayer() {
        let primary = FakeSource()
        let fallback = FakeSource()
        let source = FallbackNowPlayingSource(primary: primary, fallback: fallback)
        var title: String?
        source.start(onSnapshot: { title = $0?.title }, onFailure: {})
        primary.fail?()
        fallback.snapshot?(.init(title: "fallback", artist: nil, album: nil, isPlaying: true, sourceName: nil))
        primary.snapshot?(.init(title: "late primary", artist: nil, album: nil, isPlaying: true, sourceName: nil))
        XCTAssertEqual(title, "fallback")
        source.stop()
    }

    func testModuleRefreshDoesNotEnableDisabledModule() {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.refresh()
        XCTAssertEqual(source.startCount, 0)
        store.start()
        store.refresh()
        XCTAssertEqual(source.refreshCount, 1)
        store.stop()
        store.refresh()
        XCTAssertEqual(source.refreshCount, 1)
    }

    func testMatchingTitlesFromDifferentPlayersDoNotReuseArtworkOrDuration() {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        source.snapshot?(.init(title: "Track", artist: nil, album: nil, isPlaying: true,
                               sourceName: "music", artworkData: Data([1]), duration: 120))
        source.snapshot?(.init(title: "Track", artist: nil, album: nil, isPlaying: true, sourceName: "browser"))
        XCTAssertNil(store.snapshot?.artworkData)
        XCTAssertNil(store.snapshot?.duration)
        store.stop()
    }

    func testModuleStopReleasesSourceAndClearsActivity() {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        var activities: [IslandActivity?] = []
        store.onActivity = { activities.append($0) }
        store.start()
        source.snapshot?(.init(title: "Track", artist: nil, album: nil,
                               isPlaying: true, sourceName: nil))
        XCTAssertEqual(store.availability, .available)
        XCTAssertNotNil(store.snapshot)
        store.stop()
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(store.availability, .disabled)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(activities.last ?? nil)
    }

    func testModuleStartIsIdempotent() {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        store.start()
        XCTAssertEqual(source.startCount, 1)
        store.stop()
    }

    func testLateSourceCallbackCannotRestartStoppedModuleOrOverwriteNewSource() {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        let oldCallback = source.snapshot
        let oldFailure = source.fail
        store.stop()
        oldCallback?(.init(title: "late", artist: nil, album: nil, isPlaying: true, sourceName: nil))
        XCTAssertNil(store.snapshot)
        store.start()
        source.snapshot?(.init(title: "new", artist: nil, album: nil, isPlaying: true, sourceName: nil))
        oldCallback?(.init(title: "stale", artist: nil, album: nil, isPlaying: true, sourceName: nil))
        oldFailure?()
        XCTAssertEqual(store.snapshot?.title, "new")
        XCTAssertEqual(store.availability, .available)
        store.stop()
    }

    func testFailedSourceCannotPublishLateSnapshot() {
        let source = FakeSource()
        let store = NowPlayingModuleStore(sourceFactory: { source })
        store.start()
        let callback = source.snapshot
        source.fail?()
        callback?(.init(title: "late", artist: nil, album: nil, isPlaying: true, sourceName: nil))
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.availability, .unavailable)
        store.stop()
    }

    func testAdapterRepairReadRecoversMissingStreamEventAndCoalescesRequests() async throws {
        let fixture = try AdapterFixture(getOutput: "{\"title\":\"Recovered browser video\",\"playing\":true,\"bundleIdentifier\":\"browser\"}")
        let source = MediaRemoteAdapterSource(assets: fixture.assets)
        defer { source.stop(); fixture.remove() }
        let recovered = expectation(description: "repair read publishes browser session")
        source.start(onSnapshot: { snapshot in
            if snapshot?.title == "Recovered browser video" { recovered.fulfill() }
        }, onFailure: { XCTFail("fixture source should stay available") })
        try await fixture.waitForFile("get-started")
        for _ in 0..<5 { source.refresh() }
        XCTAssertEqual(try String(contentsOf: fixture.url("get-started"), encoding: .utf8), "get\n")
        try fixture.releaseGet()
        await fulfillment(of: [recovered], timeout: 3)
    }

    func testAdapterRepairReadCannotOverwriteNewerStreamEvent() async throws {
        let fixture = try AdapterFixture(getOutput: "{\"title\":\"Stale video\",\"playing\":true}")
        let source = MediaRemoteAdapterSource(assets: fixture.assets)
        defer { source.stop(); fixture.remove() }
        let live = expectation(description: "newer stream event")
        let stale = expectation(description: "stale repair read must be discarded")
        stale.isInverted = true
        source.start(onSnapshot: { snapshot in
            if snapshot?.title == "Live video" { live.fulfill() }
            if snapshot?.title == "Stale video" { stale.fulfill() }
        }, onFailure: { XCTFail("fixture source should stay available") })
        try await fixture.waitForFile("get-started")
        try fixture.emit("{\"type\":\"data\",\"payload\":{\"title\":\"Live video\",\"playing\":true}}")
        await fulfillment(of: [live], timeout: 3)
        try fixture.releaseGet()
        try await fixture.waitForFile("get-finished")
        await fulfillment(of: [stale], timeout: 0.2)
    }

    func testAdapterEmptyRepairReadClearsEndedSession() async throws {
        let fixture = try AdapterFixture(getOutput: "null")
        let source = MediaRemoteAdapterSource(assets: fixture.assets)
        defer { source.stop(); fixture.remove() }
        let live = expectation(description: "stream publishes playing video")
        let cleared = expectation(description: "repair read clears ended session")
        var receivedVideo = false
        source.start(onSnapshot: { snapshot in
            if snapshot != nil { receivedVideo = true; live.fulfill() }
            else if receivedVideo { cleared.fulfill() }
        }, onFailure: { XCTFail("fixture source should stay available") })
        try await fixture.waitForFile("get-started")
        try fixture.emit("{\"type\":\"data\",\"payload\":{\"title\":\"Video\",\"playing\":true}}")
        await fulfillment(of: [live], timeout: 3)
        // Complete the older read first; the next explicit read observes the
        // ended session without requiring a stream notification.
        try fixture.releaseGet()
        try await fixture.waitForFile("get-finished")
        // The callback queue must finish before requesting the next read.
        for _ in 0..<20 {
            source.refresh()
            try await Task.sleep(for: .milliseconds(10))
            if try String(contentsOf: fixture.url("get-started"), encoding: .utf8).split(separator: "\n").count > 1 { break }
        }
        await fulfillment(of: [cleared], timeout: 3)
    }

    private struct AdapterFixture {
        let root: URL
        let assets: MediaRemoteAdapterAssets

        init(getOutput: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenYoinkMediaTest-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let script = root.appendingPathComponent("adapter.pl")
            // A deterministic local subprocess stands in for the OS adapter.
            // Gates control ordering; no real player or UI is accessed.
            try Data(#"""
            use strict;
            use warnings;
            use Time::HiRes qw(usleep);
            my $root = $ARGV[0];
            my $command = $ARGV[2];
            $| = 1;
            exit 0 if $command eq 'test';
            die 'missing untitled-session option' unless grep { $_ eq '--allow-missing-title' } @ARGV;
            if ($command eq 'get') {
                open my $marker, '>>', "$root/get-started" or die $!;
                print $marker "get\n";
                close $marker;
                usleep(1000) until -e "$root/get-release";
                open my $output, '<', "$root/get-output" or die $!;
                print do { local $/; <$output> };
                close $output;
                open my $done, '>', "$root/get-finished" or die $!;
                close $done;
                exit 0;
            }
            if ($command eq 'stream') {
                open my $input, '<', "$root/stream-input" or die $!;
                while (1) {
                    while (my $line = <$input>) { print $line; }
                    seek($input, 0, 1);
                    usleep(1000);
                }
            }
            exit 1;
            """#.utf8).write(to: script)
            try Data((getOutput + "\n").utf8).write(to: root.appendingPathComponent("get-output"))
            try Data().write(to: root.appendingPathComponent("stream-input"))
            assets = .init(scriptURL: script, frameworkURL: root, testClientURL: root)
        }

        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func releaseGet() throws { try Data().write(to: url("get-release")) }
        func emit(_ line: String) throws {
            let handle = try FileHandle(forWritingTo: url("stream-input"))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        }
        func waitForFile(_ name: String) async throws {
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath: url(name).path) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("adapter fixture did not create " + name)
            throw CocoaError(.fileReadNoSuchFile)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class FakeSource: NowPlayingSource {
        var supportsTransportControls = true
        var supportsSeeking = true
        var sendResult = true
        var commands: [NowPlayingCommand] = []
        var startCount = 0
        var stopCount = 0
        var refreshCount = 0
        var snapshot: ((NowPlayingSnapshot?) -> Void)?
        var fail: (() -> Void)?

        func start(onSnapshot: @escaping @MainActor (NowPlayingSnapshot?) -> Void,
                   onFailure: @escaping @MainActor () -> Void) {
            startCount += 1
            snapshot = onSnapshot
            fail = onFailure
        }

        func stop() { stopCount += 1 }
        func refresh() { refreshCount += 1 }
        func send(_ command: NowPlayingCommand) async -> Bool {
            commands.append(command)
            return sendResult
        }
    }
}
