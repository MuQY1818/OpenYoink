import Foundation
import OSLog

/// Outcome of reading a persisted file.
///
/// `missing` (never written) and `failed` (exists but unreadable) are kept
/// apart on purpose: cleanup of app-owned files is only safe when the data
/// that references them could be read, or provably never existed.
enum LoadResult<Value: Sendable>: Sendable {
    case loaded(Value)
    case missing
    case failed

    var value: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }

    /// The on-disk state is known: either read successfully or absent.
    var isTrusted: Bool {
        switch self {
        case .loaded, .missing: true
        case .failed: false
        }
    }
}

extension LoadResult: Equatable where Value: Equatable {}

extension LoadResult where Value: RangeReplaceableCollection {
    /// Loaded contents, or an empty collection for `missing` / `failed`.
    var contents: Value { value ?? Value() }
}

/// Date representations used by the app's JSON files. Each file keeps the
/// format it has always been written in.
enum JSONDateStyle: Sendable {
    /// Foundation's default (seconds since the reference date).
    case foundationDefault
    case secondsSince1970
    /// ISO 8601 with fractional seconds; decoding also accepts whole seconds.
    case iso8601

    func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch self {
        case .foundationDefault:
            break
        case .secondsSince1970:
            encoder.dateEncodingStrategy = .secondsSince1970
        case .iso8601:
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(Self.iso8601Formatter().string(from: date))
            }
        }
        return encoder
    }

    func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        switch self {
        case .foundationDefault:
            break
        case .secondsSince1970:
            decoder.dateDecodingStrategy = .secondsSince1970
        case .iso8601:
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let string = try container.decode(String.self)
                if let date = Self.iso8601Formatter().date(from: string)
                    ?? ISO8601DateFormatter().date(from: string) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date: \(string)"
                )
            }
        }
        return decoder
    }

    static func iso8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

/// A JSON document on disk with crash-safe replacement.
///
/// Writes go to a sibling temporary file and atomically replace the target,
/// so a failed write never loses the previous version. Optionally the last
/// decodable version is kept as `<name>.backup`, and unreadable files can be
/// moved aside as `<name>.corrupt-<timestamp>` for manual recovery.
struct JSONFileStore<Document: Codable & Sendable>: Sendable {
    let url: URL
    let dateStyle: JSONDateStyle

    init(_ url: URL, dateStyle: JSONDateStyle = .foundationDefault) {
        self.url = url
        self.dateStyle = dateStyle
    }

    func readData(maximumBytes: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: url)
    }

    func writeAtomically(_ document: Document, formatting: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys]) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = dateStyle.makeEncoder()
        encoder.outputFormatting = formatting
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    var directoryURL: URL { url.deletingLastPathComponent() }
    var backupURL: URL { sibling(".backup") }
    var temporaryURL: URL { sibling(".tmp") }
    var quarantinePrefix: String { url.lastPathComponent + ".corrupt-" }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Reads the document, distinguishing a missing file from a damaged one.
    func load(logger: Logger) -> LoadResult<Document> {
        guard exists else { return .missing }
        do {
            return .loaded(try decode(contentsOf: url))
        } catch {
            logger.error("Failed to load \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    func decode(contentsOf fileURL: URL) throws -> Document {
        try dateStyle.makeDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
    }

    /// Atomically replaces the file. With `keepingBackup`, the current file
    /// is first copied to `backupURL` if it still decodes; a failed backup
    /// never blocks the write.
    func write(_ document: Document, keepingBackup: Bool, logger: Logger) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try dateStyle.makeEncoder().encode(document)
        try data.write(to: temporaryURL, options: .atomic)

        guard exists else {
            try fileManager.moveItem(at: temporaryURL, to: url)
            return
        }
        if keepingBackup {
            do {
                let previous = try Data(contentsOf: url)
                _ = try dateStyle.makeDecoder().decode(Document.self, from: previous)
                try previous.write(to: backupURL, options: .atomic)
            } catch {
                logger.warning("Could not refresh backup of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
    }

    /// Deletes the document; leftover temporary and backup files are removed
    /// best-effort.
    func delete() throws {
        let fileManager = FileManager.default
        if exists { try fileManager.removeItem(at: url) }
        try? fileManager.removeItem(at: temporaryURL)
        try? fileManager.removeItem(at: backupURL)
    }

    /// Moves an unreadable file aside so the next write starts fresh while the
    /// damaged data stays available for manual recovery.
    @discardableResult
    func quarantine(logger: Logger, suffix: String? = nil) -> URL? {
        let stamp = suffix ?? JSONDateStyle.iso8601Formatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = directoryURL.appendingPathComponent(quarantinePrefix + stamp)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            logger.warning("Quarantined damaged \(url.lastPathComponent, privacy: .public) to \(destination.path, privacy: .public)")
            return destination
        } catch {
            logger.error("Failed to quarantine damaged \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func sibling(_ suffix: String) -> URL {
        directoryURL.appendingPathComponent(url.lastPathComponent + suffix)
    }
}

/// Coalesces rapid saves into one write after `interval`.
@MainActor
final class DebouncedWriter<Value> {
    private let interval: Duration
    private let write: @MainActor (Value) -> Void
    private var pending: Value?
    private var task: Task<Void, Never>?

    init(interval: Duration, write: @escaping @MainActor (Value) -> Void) {
        self.interval = interval
        self.write = write
    }

    func schedule(_ value: Value) {
        pending = value
        task?.cancel()
        task = Task { [weak self, interval] in
            do { try await Task.sleep(for: interval) } catch { return }
            self?.flush()
        }
    }

    /// Writes any pending value now.
    func flush() {
        task?.cancel()
        task = nil
        guard let value = pending else { return }
        pending = nil
        write(value)
    }

    /// Drops any pending value without writing it.
    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
