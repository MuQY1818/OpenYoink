import XCTest
@testable import OpenYoink

@MainActor
final class PersistenceControllerTests: XCTestCase {
    // MARK: - Helpers

    /// Creates a fresh, empty directory in the container temp directory.
    /// Cleaned up with `defer` at each call site (XCTestCase teardown overrides
    /// are nonisolated and cannot touch MainActor state).
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Dates use exactly representable fractional seconds so the ISO8601
    /// (millisecond) encoding round-trips losslessly.
    private func makeItem(_ name: String) -> ShelfItem {
        ShelfItem(
            kind: .file,
            path: "/tmp/\(name)",
            displayName: name,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000.5)
        )
    }

    // MARK: - Round trip

    func testSaveThenLoad_roundTripsItems() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        let items = [makeItem("a"), makeItem("b")]

        try controller.saveNow(items)

        XCTAssertEqual(controller.loadResult().contents, items)
        XCTAssertEqual(controller.saveCount, 1)
    }

    func testLoad_missingFile_returnsEmptyArray() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.loadResult().contents, [])
    }

    func testSave_createsSchemaVersionEnvelope() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        try controller.saveNow([makeItem("a")])

        let data = try Data(contentsOf: directory.appendingPathComponent("shelf.json"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(envelope["schemaVersion"] as? Int, PersistenceController.currentSchemaVersion)
        XCTAssertNotNil(envelope["items"])
    }

    /// A file written by a newer app version must not crash; unknown fields are
    /// ignored by the decoder (best-effort forward compatibility).
    func testLoad_newerSchemaVersion_decodesBestEffort() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {
            "schemaVersion": 99,
            "futureField": {"anything": true},
            "items": []
        }
        """
        try json.write(
            to: directory.appendingPathComponent("shelf.json"),
            atomically: true,
            encoding: .utf8
        )

        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.loadResult().contents, [])
    }

    // MARK: - Corrupted data

    func testLoad_corruptedJSON_returnsEmptyArray_andRecovers() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "not json {{{".write(
            to: directory.appendingPathComponent("shelf.json"),
            atomically: true,
            encoding: .utf8
        )

        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.loadResult().contents, [])

        // The controller stays usable after a corrupted read.
        try controller.saveNow([makeItem("recovered")])
        XCTAssertEqual(controller.loadResult().contents.map(\.displayName), ["recovered"])
    }

    func testLoadResult_missingFile_returnsMissing() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.loadResult(), .missing)
    }

    func testLoadResult_validFile_returnsLoaded() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        try controller.saveNow([makeItem("a"), makeItem("b")])
        guard case .loaded(let items) = controller.loadResult() else {
            return XCTFail("expected .loaded, got \(controller.loadResult())")
        }
        XCTAssertEqual(items.map(\.displayName), ["a", "b"])
    }

    /// A corrupt file must load as .failed and be kept in quarantine, not
    /// silently read as an empty shelf, so launch skips orphan cleanup instead
    /// of deleting managed files in Materialized.
    func testLoadResult_corruptedJSON_returnsFailed_andQuarantinesFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelfURL = directory.appendingPathComponent("shelf.json")
        try "not json {{{".write(to: shelfURL, atomically: true, encoding: .utf8)

        let controller = PersistenceController(directoryURL: directory)
        XCTAssertEqual(controller.loadResult(), .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfURL.path),
                       "Move the corrupt file out of its original location.")
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("shelf.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 1, "the corrupt file should be quarantined for manual recovery")
    }

    /// Launch must reuse the first read: the first read quarantines a corrupt
    /// file and a second one reports missing; deciding cleanup from the second
    /// would delete every file in Materialized.
    func testLoadResult_failedSnapshotNeverPermitsOrphanCleanup_afterQuarantine() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "not json {{{".write(
            to: directory.appendingPathComponent("shelf.json"),
            atomically: true,
            encoding: .utf8
        )
        let controller = PersistenceController(directoryURL: directory)

        let initialResult = controller.loadResult()

        XCTAssertEqual(initialResult, .failed)
        XCTAssertEqual(initialResult.contents, [])
        XCTAssertFalse(initialResult.isTrusted)
        XCTAssertFalse(controller.canSafelyCleanupMaterializedOrphans(after: initialResult))
        XCTAssertEqual(controller.loadResult(), .missing,
                       "A read after quarantine reports missing. Startup must retain the first result.")
        XCTAssertFalse(initialResult.isTrusted,
                       "The initial load failure must block orphan cleanup for this launch.")
        XCTAssertFalse(
            controller.canSafelyCleanupMaterializedOrphans(after: .missing),
            "while a quarantined snapshot exists, later launches must keep recovery material even when reading missing"
        )
    }

    func testLoadResult_trustedSnapshotsPermitOrphanCleanup() throws {
        XCTAssertTrue(PersistenceController.LoadResult.missing.isTrusted)
        XCTAssertTrue(PersistenceController.LoadResult.loaded([]).isTrusted)

        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        XCTAssertTrue(controller.canSafelyCleanupMaterializedOrphans(after: .missing))
        XCTAssertTrue(controller.canSafelyCleanupMaterializedOrphans(after: .loaded([])))
    }

    func testOrphanCleanup_staysBlockedWhenValidShelfCoexistsWithRecoverySnapshot() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        try controller.saveNow([makeItem("new")])
        try "recoverable".write(
            to: directory.appendingPathComponent("shelf.json.corrupt-old"),
            atomically: true,
            encoding: .utf8
        )

        let result = controller.loadResult()

        guard case .loaded = result else { return XCTFail("expected valid current snapshot") }
        XCTAssertFalse(controller.canSafelyCleanupMaterializedOrphans(after: result),
                       "A new snapshot must preserve the user's existing recovery data.")
    }

    func testWrite_existingFile_atomicallyReplaced() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        try controller.saveNow([makeItem("old")])
        try controller.saveNow([makeItem("new-1"), makeItem("new-2")])
        XCTAssertEqual(controller.loadResult().contents.map(\.displayName), ["new-1", "new-2"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("shelf.json.tmp").path))
    }

    // MARK: - Recovery snapshots

    func testSaveOverExistingSnapshot_preservesLastKnownGoodBackup() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)

        try controller.saveNow([makeItem("old")])
        try controller.saveNow([makeItem("new")])

        let backup = try XCTUnwrap(
            controller.recoverySnapshots().first { $0.kind == .lastKnownGood }
        )
        XCTAssertTrue(backup.isRecoverable)
        XCTAssertEqual(try controller.loadRecoverySnapshot(backup).map(\.displayName), ["old"])
        XCTAssertEqual(controller.loadResult().contents.map(\.displayName), ["new"])
    }

    func testRecoverySnapshots_marksDamagedQuarantineAsUnreadable() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let damagedURL = directory.appendingPathComponent("shelf.json.corrupt-test")
        try "broken".write(to: damagedURL, atomically: true, encoding: .utf8)
        let controller = PersistenceController(directoryURL: directory)

        let snapshot = try XCTUnwrap(controller.recoverySnapshots().first)

        XCTAssertEqual(snapshot.kind, .quarantined)
        XCTAssertFalse(snapshot.isRecoverable)
        XCTAssertThrowsError(try controller.loadRecoverySnapshot(snapshot)) { error in
            XCTAssertEqual(error as? PersistenceController.RecoveryError, .snapshotIsUnreadable)
        }
    }

    func testRecoverySnapshot_refusesURLOutsideManagedDirectory() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        let outside = PersistenceController.RecoverySnapshot(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("shelf.json.backup"),
            kind: .lastKnownGood,
            modifiedAt: nil,
            byteCount: 0,
            isRecoverable: true
        )

        XCTAssertThrowsError(try controller.loadRecoverySnapshot(outside)) { error in
            XCTAssertEqual(error as? PersistenceController.RecoveryError, .invalidSnapshot)
        }
    }

    // MARK: - Debounce

    func testScheduledSaves_coalesceIntoSingleDiskWrite() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(
            directoryURL: directory,
            debounceInterval: .milliseconds(50)
        )

        controller.scheduleSave([makeItem("a")])
        controller.scheduleSave([makeItem("a"), makeItem("b")])
        controller.scheduleSave([makeItem("a"), makeItem("b"), makeItem("c")])

        // Generous margin over the 50ms debounce; suspending (not blocking)
        // keeps the main actor free to run the debounced write.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(controller.saveCount, 1)
        XCTAssertEqual(controller.loadResult().contents.map(\.displayName), ["a", "b", "c"])
    }

    func testFlushPendingSave_writesImmediatelyAndCancelsDebounce() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(
            directoryURL: directory,
            debounceInterval: .milliseconds(50)
        )

        controller.scheduleSave([makeItem("a")])
        controller.flushPendingSave()

        XCTAssertEqual(controller.saveCount, 1)
        XCTAssertEqual(controller.loadResult().contents.map(\.displayName), ["a"])

        // The cancelled debounce task must not write again.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.saveCount, 1)
    }

    func testFlushPendingSave_withoutPendingSave_isNoOp() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PersistenceController(directoryURL: directory)
        controller.flushPendingSave()
        XCTAssertEqual(controller.saveCount, 0)
    }
}
