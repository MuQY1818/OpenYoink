import Foundation
import Observation

extension IslandModuleID {
    static let notes = Self(rawValue: "notes")
}

/// Island notes module: a single scratch note that lives in the menu-bar
/// app and survives relaunches. Text is stored as plain UTF-8 (`notes.txt`)
/// in the app's Application Support directory, written atomically and debounced.
@MainActor
@Observable
final class NotesModuleStore {
    static let moduleDescriptor = IslandModuleDescriptor(
        id: .notes,
        title: String(localized: "Notes"),
        systemImage: "note.text",
        order: 10,
        isCore: false
    )

    /// Current note text. Setting it schedules a debounced save.
    var text: String {
        didSet {
            guard isLoaded else { return }
            scheduleSave()
        }
    }

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(directoryURL: URL = AppDirectories.applicationSupport(),
         debounce: Duration = .milliseconds(500)) {
        self.fileURL = directoryURL.appendingPathComponent("notes.txt")
        self.debounce = debounce
        let loaded = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        self.text = loaded
        self.isLoaded = true
    }

    /// One-tap clear: empty the note and persist immediately so an empty state
    /// survives the next launch.
    func clear() {
        saveTask?.cancel()
        text = ""
        saveNow()
    }

    /// Write any pending change immediately (called when the module leaves the
    /// screen, so a note edited right before quitting is not lost to debounce).
    func flush() {
        saveTask?.cancel()
        saveNow()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard let data = text.data(using: .utf8) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
