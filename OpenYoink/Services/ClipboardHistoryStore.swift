import AppKit
import Observation

@MainActor
@Observable
final class ClipboardHistoryStore {
    private(set) var entries: [ClipboardHistoryEntry] = []
    private(set) var isRecording = false
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    var shortcutRegistrationError: String?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let persistence: ClipboardHistoryPersistence
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastChangeCount: Int
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var canWrite = true
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored nonisolated(unsafe) private var resourceToken: NSObjectProtocol?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sourceIsIgnored: () -> Bool
    var onAddToShelf: ((ClipboardHistoryEntry.Content) -> Void)?
    var onShowWindow: (() -> Void)?

    init(settings: SettingsStore, pasteboard: NSPasteboard = .general,
         directoryURL: URL = AppDirectories.applicationSupport(), now: @escaping () -> Date = Date.init,
         sourceIsIgnored: (() -> Bool)? = nil) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.persistence = ClipboardHistoryPersistence(directoryURL: directoryURL)
        self.now = now
        self.sourceIsIgnored = sourceIsIgnored ?? {
            IgnoreListService.frontmostAppIsIgnored(in: settings.ignoredAppBundleIDs)
        }
        lastChangeCount = pasteboard.changeCount
        _ = ResourceUsageState.shared
        resourceToken = NotificationCenter.default.addObserver(forName: .openYoinkResourcePolicyDidChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateRecording() }
        }
    }

    deinit {
        pollTask?.cancel()
        loadTask?.cancel()
        saveTask?.cancel()
        if let resourceToken { NotificationCenter.default.removeObserver(resourceToken) }
    }

    func start() {
        isStarted = true
        if loadTask == nil && isLoading {
            loadTask = Task { @MainActor [weak self, persistence] in
                do {
                    let loaded = try await persistence.load()
                    guard let self, !Task.isCancelled else { return }
                    if revision == 0 {
                        entries = ClipboardHistoryPolicy.trimmed(loaded, now: now(), retentionDays: settings.clipboardHistoryRetentionDays,
                                                                 entryLimit: settings.clipboardHistoryEntryLimit)
                        if entries != loaded { persist() }
                    }
                } catch {
                    guard let self else { return }
                    if revision == 0 {
                        canWrite = false
                        errorMessage = String(localized: "Clipboard history could not be loaded. Clear history to reset it.")
                    }
                }
                guard let self else { return }
                isLoading = false
                updateRecording()
            }
        }
        updateRecording()
    }

    func stop() {
        isStarted = false
        stopPolling()
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isRecording = false
        lastChangeCount = pasteboard.changeCount
    }

    func updateRecording() {
        prune()
        guard isStarted, !isLoading, settings.clipboardHistoryEnabled, !settings.clipboardHistoryPaused,
              ResourceUsageState.shared.samplingAllowed else {
            stopPolling()
            return
        }
        guard pollTask == nil else { return }
        // Opting in / resuming never retroactively captures existing contents.
        lastChangeCount = pasteboard.changeCount
        isRecording = true
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.poll()
            }
        }
    }

    func poll() {
        guard isRecording, settings.clipboardHistoryEnabled, !settings.clipboardHistoryPaused else { return }
        prune()
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        let types = Set((pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
            .union((pasteboard.types ?? []).map(\.rawValue))
        guard ClipboardHistoryPolicy.permits(types: types, sourceIsIgnored: sourceIsIgnored()) else { return }
        var content: ClipboardHistoryEntry.Content?
        if let data = pasteboard.data(forType: .png), data.count <= ClipboardHistoryPolicy.maximumImageBytes {
            content = .image(data, type: NSPasteboard.PasteboardType.png.rawValue)
        } else if let data = pasteboard.data(forType: .tiff), data.count <= ClipboardHistoryPolicy.maximumImageBytes {
            content = .image(data, type: NSPasteboard.PasteboardType.tiff.rawValue)
        } else if let value = pasteboard.string(forType: .URL), ClipboardHistoryEntry.Content.url(value).isValid {
            content = .url(value)
        } else if let value = pasteboard.string(forType: .string) {
            content = ClipboardHistoryEntry.Content.url(value).isValid ? .url(value) : .text(value)
        }
        guard pasteboard.changeCount == changeCount, let content, content.isValid else { return }
        let next = ClipboardHistoryPolicy.inserting(content, into: entries, now: now(), retentionDays: settings.clipboardHistoryRetentionDays,
                                                     entryLimit: settings.clipboardHistoryEntryLimit)
        guard next.contains(where: { $0.content == content }) else {
            noticeMessage = String(localized: "History storage is full. Remove a favorite or an image to record more.")
            return
        }
        entries = next
        persist()
    }

    @discardableResult
    func copy(_ entry: ClipboardHistoryEntry) -> Bool {
        let item = NSPasteboardItem()
        switch entry.content {
        case .text(let value): item.setString(value, forType: .string)
        case .url(let value):
            item.setString(value, forType: .URL)
            item.setString(value, forType: .string)
        case .image(let data, let type): item.setData(data, forType: .init(type))
        }
        pasteboard.clearContents()
        let success = pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
        noticeMessage = success ? String(localized: "Copied to Clipboard") : String(localized: "Copy failed")
        return success
    }

    func addToShelf(_ entry: ClipboardHistoryEntry) {
        onAddToShelf?(entry.content)
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist(immediately: true)
    }

    func clear() {
        entries = []
        lastChangeCount = pasteboard.changeCount
        canWrite = true
        errorMessage = nil
        noticeMessage = nil
        persist(immediately: true)
    }

    func setFavorite(_ favorite: Bool, id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if favorite && !entries[index].isFavorite,
           entries.filter(\.isFavorite).count >= ClipboardHistoryPolicy.maximumFavorites {
            noticeMessage = String(localized: "You can keep up to 30 favorites.")
            return
        }
        entries[index].isFavorite = favorite
        prune(force: true)
        persist()
    }

    func filteredEntries(query: String, filter: ClipboardContentFilter = .all) -> [ClipboardHistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            filter.includes($0) && (query.isEmpty || $0.content.searchText.localizedCaseInsensitiveContains(query))
        }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.copiedAt > $1.copiedAt
        }
    }

    func prune(force: Bool = false) {
        guard force || now().timeIntervalSince(lastPrune) >= 60 else { return }
        lastPrune = now()
        let trimmed = ClipboardHistoryPolicy.trimmed(entries, now: now(), retentionDays: settings.clipboardHistoryRetentionDays,
                                                     entryLimit: settings.clipboardHistoryEntryLimit)
        guard entries != trimmed else { return }
        entries = trimmed
        persist()
    }

    private func persist(immediately: Bool = false) {
        guard canWrite else { return }
        saveTask?.cancel()
        revision += 1
        let revision = revision
        let entries = entries
        saveTask = Task { @MainActor [weak self, persistence] in
            if !immediately {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            do {
                try await persistence.save(entries, revision: revision)
                if self?.revision == revision { self?.errorMessage = nil }
            } catch {
                if self?.revision == revision {
                    self?.errorMessage = String(localized: "Clipboard history could not be saved.")
                }
            }
        }
    }

    func flush() async {
        if isLoading {
            guard let loadTask else { return }
            await loadTask.value
        }
        guard canWrite else { return }
        saveTask?.cancel()
        revision += 1
        do {
            try await persistence.save(entries, revision: revision)
        } catch {
            errorMessage = String(localized: "Clipboard history could not be saved.")
        }
    }
}
