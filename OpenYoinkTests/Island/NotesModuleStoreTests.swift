import XCTest
@testable import OpenYoink

@MainActor
final class NotesModuleStoreTests: XCTestCase {
    private var tempDir: URL!
    private var debounce: Duration = .zero

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesModuleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testStartsEmptyOnFreshInstall() {
        let store = NotesModuleStore(directoryURL: tempDir, debounce: .zero)
        XCTAssertEqual(store.text, "")
    }

    func testLoadsExistingNote() throws {
        let url = tempDir.appendingPathComponent("notes.txt")
        try "remember this".data(using: .utf8)!.write(to: url)
        let store = NotesModuleStore(directoryURL: tempDir, debounce: .zero)
        XCTAssertEqual(store.text, "remember this")
    }

    func testClearPersistsImmediately() throws {
        let url = tempDir.appendingPathComponent("notes.txt")
        try "junk".data(using: .utf8)!.write(to: url)
        let store = NotesModuleStore(directoryURL: tempDir, debounce: .zero)
        store.clear()
        XCTAssertEqual(store.text, "")
        // A fresh instance (simulating relaunch) must also see it empty.
        XCTAssertEqual(NotesModuleStore(directoryURL: tempDir, debounce: .zero).text, "")
    }

    func testTypingIsSavedAfterDebounce() async throws {
        let store = NotesModuleStore(directoryURL: tempDir, debounce: .milliseconds(10))
        store.text = "hello note"
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(NotesModuleStore(directoryURL: tempDir, debounce: .zero).text, "hello note")
    }

    func testFlushWritesPendingTextImmediately() throws {
        let store = NotesModuleStore(directoryURL: tempDir, debounce: .seconds(60))
        store.text = "flushed"
        store.flush()
        XCTAssertEqual(NotesModuleStore(directoryURL: tempDir, debounce: .zero).text, "flushed")
    }

    func testDescriptorIsRegisteredInModuleLibrary() {
        let registry = IslandModuleRegistry()
        XCTAssertTrue(registry.descriptors.contains { $0.id == .notes })
    }
}
