import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var pasteboard: NSPasteboard!
    private var settings: SettingsStore!
    private var history: ClipboardHistoryStore!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var ignored = false

    override func setUp() async throws {
        suite = "OpenYoinkClipboardTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pasteboard = NSPasteboard.withUniqueName()
        settings = SettingsStore(defaults: defaults)
        history = ClipboardHistoryStore(settings: settings, pasteboard: pasteboard, directoryURL: directory,
                                        now: { [unowned self] in self.clock },
                                        sourceIsIgnored: { [unowned self] in self.ignored })
    }

    override func tearDown() async throws {
        history.stop()
        await history.flush()
        history = nil
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func start(enabled: Bool = true) async throws {
        settings.clipboardHistoryEnabled = enabled
        history.start()
        for _ in 0..<200 where history.isLoading {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(history.isLoading)
    }

    private func write(_ value: String, type: NSPasteboard.PasteboardType = .string,
                       extraType: String? = nil) {
        let item = NSPasteboardItem()
        item.setString(value, forType: type)
        if let extraType { item.setData(Data(), forType: .init(extraType)) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private func imageData(width: Int = 2, height: Int = 2) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.systemBlue, atX: 0, y: 0)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testDefaultsAreOptInAndModuleIsOptional() {
        XCTAssertFalse(settings.clipboardHistoryEnabled)
        XCTAssertFalse(settings.clipboardHistoryPaused)
        XCTAssertEqual(settings.clipboardHistoryRetentionDays, 7)
        XCTAssertFalse(settings.isIslandModuleEnabled(.clipboard))
    }

    func testSettingsRoundTripAndInvalidRetention() {
        settings.clipboardHistoryEnabled = true
        settings.clipboardHistoryPaused = true
        settings.clipboardHistoryRetentionDays = 30
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.clipboardHistoryEnabled)
        XCTAssertTrue(reloaded.clipboardHistoryPaused)
        XCTAssertEqual(reloaded.clipboardHistoryRetentionDays, 30)
        defaults.set(-1, forKey: "OpenYoink.clipboardHistoryRetentionDays")
        XCTAssertEqual(SettingsStore(defaults: defaults).clipboardHistoryRetentionDays, 7)
    }

    func testStartDoesNotReadExistingClipboard() async throws {
        write("before opt in")
        try await start()
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)
        write("after opt in")
        history.poll()
        XCTAssertEqual(history.entries.first?.content, .text("after opt in"))
    }

    func testDisabledDoesNotCapture() async throws {
        try await start(enabled: false)
        write("private")
        history.poll()
        XCTAssertFalse(history.isRecording)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPauseAndResumeSkipPausedClipboard() async throws {
        try await start()
        settings.clipboardHistoryPaused = true
        history.updateRecording()
        write("paused copy")
        history.poll()
        settings.clipboardHistoryPaused = false
        history.updateRecording()
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)
        write("new copy")
        history.poll()
        XCTAssertEqual(history.entries.count, 1)
    }

    func testStopBeforeLoadFinishesDoesNotRestartPolling() async throws {
        settings.clipboardHistoryEnabled = true
        history.start()
        history.stop()
        for _ in 0..<200 where history.isLoading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(history.isRecording)
    }

    func testRepeatedPollingIsIdempotent() async throws {
        try await start()
        write("one")
        history.poll()
        history.poll()
        XCTAssertEqual(history.entries.count, 1)
    }

    func testDuplicateMovesToFrontWithStableID() async throws {
        try await start()
        write("first")
        history.poll()
        let id = history.entries.first?.id
        clock += 1
        write("second")
        history.poll()
        clock += 1
        write("first")
        history.poll()
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries.first?.id, id)
        XCTAssertEqual(history.entries.first?.copiedAt, clock)
    }

    func testURLsAndSearch() async throws {
        try await start()
        write("https://example.com/Hello")
        history.poll()
        XCTAssertEqual(history.entries.first?.content, .url("https://example.com/Hello"))
        XCTAssertEqual(history.filteredEntries(query: " HELLO ").count, 1)
        XCTAssertTrue(history.filteredEntries(query: "absent").isEmpty)
        write("https://example.org", type: .URL)
        history.poll()
        XCTAssertEqual(history.entries.first?.content, .url("https://example.org"))
    }

    func testImagesRoundTripWithoutSelfCapture() async throws {
        try await start()
        let data = try imageData()
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        history.poll()
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.content, .image(data, type: "public.png"))
        XCTAssertTrue(history.copy(entry))
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        history.poll()
        XCTAssertEqual(history.entries.count, 1)
    }

    func testCopyDoesNotReorderOrCaptureItself() async throws {
        try await start()
        write("first")
        history.poll()
        let first = try XCTUnwrap(history.entries.first)
        clock += 1
        write("second")
        history.poll()
        XCTAssertTrue(history.copy(first))
        history.poll()
        XCTAssertEqual(history.entries.first?.content, .text("second"))
        XCTAssertEqual(pasteboard.string(forType: .string), "first")
    }

    func testPrivacyMarkersAndFilesAreSkipped() async throws {
        try await start()
        for marker in ClipboardHistoryPolicy.sensitiveTypes.subtracting(["PasswordPboardType"]).union(["public.file-url"]) {
            write("never save", extraType: marker)
            history.poll()
            XCTAssertTrue(history.entries.isEmpty, "Marker: \(marker); types: \((pasteboard.types ?? []).map(\.rawValue))")
            history.clear()
        }
        XCTAssertFalse(ClipboardHistoryPolicy.permits(types: ["PasswordPboardType"], sourceIsIgnored: false))
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPrivacyMarkerOnSecondPasteboardItemProtectsEntireCopy() async throws {
        try await start()
        let first = NSPasteboardItem()
        first.setString("secret", forType: .string)
        let second = NSPasteboardItem()
        second.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testIgnoredSourceDoesNotCaptureOrRetroactivelyCapture() async throws {
        try await start()
        ignored = true
        write("private")
        history.poll()
        ignored = false
        history.poll()
        XCTAssertTrue(history.entries.isEmpty)
        write("allowed")
        history.poll()
        XCTAssertEqual(history.entries.count, 1)
    }

    func testMalformedAndOversizeContentIsRejected() {
        XCTAssertFalse(ClipboardHistoryEntry.Content.text(" \n ").isValid)
        XCTAssertFalse(ClipboardHistoryEntry.Content.text(String(repeating: "a", count: 262_145)).isValid)
        XCTAssertFalse(ClipboardHistoryEntry.Content.url("file:///private/secret").isValid)
        XCTAssertFalse(ClipboardHistoryEntry.Content.url("https:").isValid)
        XCTAssertFalse(ClipboardHistoryEntry.Content.image(Data([1, 2]), type: "public.png").isValid)
        XCTAssertFalse(ClipboardHistoryEntry.Content.image(Data(count: 5_242_881), type: "public.png").isValid)
    }

    func testCountAndExpiryLimits() {
        let entries = (0..<40).map { ClipboardHistoryEntry(copiedAt: clock - Double($0), content: .text("\($0)")) }
        XCTAssertEqual(ClipboardHistoryPolicy.trimmed(entries, now: clock, retentionDays: 7).count, 30)
        let expired = ClipboardHistoryEntry(copiedAt: clock - 86_400, content: .text("expired"))
        XCTAssertTrue(ClipboardHistoryPolicy.trimmed([expired], now: clock, retentionDays: 1).isEmpty)
    }

    func testTotalImageByteLimit() throws {
        let png = try imageData()
        let entries = (0..<5).map { index in
            var data = png
            data.append(Data(repeating: UInt8(index), count: ClipboardHistoryPolicy.maximumImageBytes - png.count))
            return ClipboardHistoryEntry(copiedAt: clock - Double(index), content: .image(data, type: "public.png"))
        }
        XCTAssertTrue(entries.allSatisfy { $0.content.isValid })
        let trimmed = ClipboardHistoryPolicy.trimmed(entries, now: clock, retentionDays: 7)
        XCTAssertEqual(trimmed.count, 4)
        XCTAssertEqual(trimmed.reduce(0) { $0 + $1.content.byteCount }, ClipboardHistoryPolicy.maximumTotalBytes)
    }

    func testRetentionChangePrunesImmediately() async throws {
        try await start()
        write("old")
        history.poll()
        clock += 2 * 86_400
        settings.clipboardHistoryRetentionDays = 1
        history.prune(force: true)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testDeleteAndAddToShelfCallback() async throws {
        try await start()
        write("content")
        history.poll()
        let entry = try XCTUnwrap(history.entries.first)
        var added: ClipboardHistoryEntry.Content?
        history.onAddToShelf = { added = $0 }
        history.addToShelf(entry)
        XCTAssertEqual(added, entry.content)
        XCTAssertEqual(history.entries.count, 1)
        history.remove(entry.id)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPersistenceRoundTripAndPermissions() async throws {
        let persistence = ClipboardHistoryPersistence(directoryURL: directory)
        let entries = [ClipboardHistoryEntry(copiedAt: clock, content: .text("persisted"))]
        try await persistence.save(entries, revision: 1)
        let loaded = try await persistence.load()
        XCTAssertEqual(loaded, entries)
        let url = directory.appendingPathComponent("clipboard-history.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testLateSaveCannotUndoClear() async throws {
        let persistence = ClipboardHistoryPersistence(directoryURL: directory)
        try await persistence.save([], revision: 3)
        try await persistence.save([ClipboardHistoryEntry(content: .text("old"))], revision: 2)
        let loaded = try await persistence.load()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clipboard-history.json").path))
    }

    func testClearFlushDoesNotTouchSystemClipboardAndSurvivesQueuedSaves() async throws {
        try await start()
        for i in 0..<10 { write("\(i)"); history.poll() }
        history.clear()
        await history.flush()
        XCTAssertEqual(pasteboard.string(forType: .string), "9")
        let loaded = try await ClipboardHistoryPersistence(directoryURL: directory).load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testCorruptHistoryIsNotOverwrittenUntilExplicitClear() async throws {
        let url = directory.appendingPathComponent("clipboard-history.json")
        let corrupt = Data("broken history".utf8)
        try corrupt.write(to: url)
        try await start()
        XCTAssertNotNil(history.errorMessage)
        write("new")
        history.poll()
        await history.flush()
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        history.clear()
        await history.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnknownSchemaIsRejectedWithoutMutation() async throws {
        let url = directory.appendingPathComponent("clipboard-history.json")
        let data = Data("{\"version\":99,\"entries\":[]}".utf8)
        try data.write(to: url)
        do {
            _ = try await ClipboardHistoryPersistence(directoryURL: directory).load()
            XCTFail("Unknown schema must not be treated as empty history")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
