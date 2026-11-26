import Foundation
import XCTest
@testable import OpenYoink

/// TempFileService's age-based staging cleanup (shared promise staging is
/// never cleaned in callbacks; launch reclaims it by age).
final class TempFileServiceTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-TFS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Old PromiseStaging directories go; new ones and unrelated entries stay.
    func testCleanupStaleStagingDirectories_removesOnlyOldStaging() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let fileManager = FileManager.default

        let oldStaging = try service.createPromiseStagingDirectory()
        let newStaging = try service.createPromiseStagingDirectory()
        let materializedFile = directory.appendingPathComponent("\(UUID().uuidString)-photo.png")
        try "x".write(to: materializedFile, atomically: true, encoding: .utf8)
        // Backdate oldStaging's modification time by two hours.
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try fileManager.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: oldStaging.path)

        service.cleanupStaleStagingDirectories(maxAge: 3600)

        XCTAssertFalse(fileManager.fileExists(atPath: oldStaging.path), "old staging should be removed")
        XCTAssertTrue(fileManager.fileExists(atPath: newStaging.path), "new staging must stay")
        XCTAssertTrue(fileManager.fileExists(atPath: materializedFile.path), "entries other than staging are untouched")
    }

    /// Cleanup never reaches beyond its scope: directories without the
/// PromiseStaging prefix are left alone.
    func testCleanupStaleStagingDirectories_ignoresNonStagingDirectories() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let other = directory.appendingPathComponent("SomeOtherDir", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: other.path)

        service.cleanupStaleStagingDirectories(maxAge: 3600)

        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testCleanupStaleStagingDirectories_preservesJournaledPayload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let staging = try service.createPromiseStagingDirectory()
        let payload = staging.appendingPathComponent("received.txt")
        try Data("retained".utf8).write(to: payload)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86400)],
            ofItemAtPath: staging.path
        )

        service.cleanupStaleStagingDirectories(
            maxAge: 3600,
            keepingPaths: [payload.path]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    func testCreatePromiseStagingDirectory_usesCleanupCompatibleName() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)

        let staging = try service.createPromiseStagingDirectory()
        var isDirectory: ObjCBool = false

        XCTAssertTrue(staging.lastPathComponent.hasPrefix("PromiseStaging-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// Regular orphan cleanup must skip staging that may still be written;
    /// only cleanupStaleStagingDirectories reclaims it.
    func testCleanupOrphans_preservesPromiseStaging_butRemovesOrdinaryOrphan() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let staging = try service.createPromiseStagingDirectory()
        let orphan = try service.uniqueFileURL(suggestedName: "orphan.txt")
        try "x".write(to: orphan, atomically: true, encoding: .utf8)

        service.cleanupOrphans()

        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testCleanupOrphans_reportsRemovedItemsAndPreservesReferencedFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let kept = try service.uniqueFileURL(suggestedName: "kept.bin")
        let orphan = try service.uniqueFileURL(suggestedName: "orphan.bin")
        try Data(repeating: 1, count: 4_096).write(to: kept)
        try Data(repeating: 2, count: 8_192).write(to: orphan)

        XCTAssertGreaterThan(service.storageUsage(), 0)
        let result = service.cleanupOrphans(keepingPaths: [kept.path])

        XCTAssertEqual(result.removedItemCount, 1)
        XCTAssertGreaterThan(result.reclaimedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
