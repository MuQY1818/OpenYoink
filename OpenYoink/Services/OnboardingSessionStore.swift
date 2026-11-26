import Foundation

final class OnboardingSessionStore {
    struct Record: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable {
            case awaitingImport
            case awaitingExport
        }

        var sessionID: UUID
        var token: String
        var phase: Phase
        var tutorialItemID: UUID?
        var createdAt: Date
    }

    enum StoreError: Error, Equatable {
        case invalidSessionDirectory
    }

    static let tutorialFileName = "OpenYoink 练习文件.txt"

    let rootURL: URL
    private let fileManager: FileManager

    private let recordFile: JSONFileStore<Record>

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL
            ?? AppPaths.applicationSupport().appendingPathComponent("Tutorial", isDirectory: true)
        self.recordFile = JSONFileStore(self.rootURL.appendingPathComponent("tutorial-session.json"))
        self.fileManager = fileManager
    }

    func begin() throws -> Record {
        try discardAll()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let record = Record(sessionID: UUID(),
                            token: UUID().uuidString,
                            phase: .awaitingImport,
                            tutorialItemID: nil,
                            createdAt: Date())
        let directory = try sessionDirectory(for: record.sessionID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let contents = String(localized: "This practice file was created by OpenYoink. You can delete it safely.")
        try Data(contents.utf8).write(to: tutorialFileURL(for: record), options: .atomic)
        try save(record)
        return record
    }

    func load() -> Record? {
        guard let record = try? recordFile.decode(contentsOf: recordFile.url),
              !record.token.isEmpty,
              (record.phase == .awaitingImport || record.tutorialItemID != nil),
              (try? sessionDirectory(for: record.sessionID)) != nil else {
            return nil
        }
        return record
    }

    func markAwaitingExport(_ record: Record, tutorialItemID: UUID) throws -> Record {
        var updated = record
        updated.phase = .awaitingExport
        updated.tutorialItemID = tutorialItemID
        try save(updated)
        return updated
    }

    func tutorialFileURL(for record: Record) -> URL {
        rootURL
            .appendingPathComponent(record.sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.tutorialFileName, isDirectory: false)
    }

    /// Deletes one session, after verifying the directory is a UUID-named direct
    /// child of the Tutorial root; nothing outside it is accepted.
    func discard(_ record: Record) throws {
        let directory = try sessionDirectory(for: record.sessionID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        if fileManager.fileExists(atPath: recordFile.url.path) {
            try fileManager.removeItem(at: recordFile.url)
        }
    }

    func discardAll() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
    }

    func isTutorialFile(_ url: URL, for record: Record) -> Bool {
        url.standardizedFileURL == tutorialFileURL(for: record).standardizedFileURL
    }

    private func save(_ record: Record) throws {
        _ = try sessionDirectory(for: record.sessionID)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try recordFile.writeAtomically(record)
    }

    private func sessionDirectory(for sessionID: UUID) throws -> URL {
        let root = rootURL.standardizedFileURL
        let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              UUID(uuidString: directory.lastPathComponent) == sessionID else {
            throw StoreError.invalidSessionDirectory
        }
        return directory
    }
}
