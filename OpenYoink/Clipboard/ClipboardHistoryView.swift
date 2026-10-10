import AppKit
import ImageIO
import SwiftUI

struct ClipboardHistoryView: View {
    let isIsland: Bool
    @Environment(ClipboardHistoryStore.self) private var history
    @Environment(SettingsStore.self) private var settings
    @State private var query = ""
    @State private var filter: ClipboardContentFilter = .all
    @FocusState private var searchFocused: Bool
    @State private var confirmsClear = false
    @State private var preview: ClipboardHistoryEntry?

    init(isIsland: Bool = false) {
        self.isIsland = isIsland
    }

    private var primaryForeground: Color {
        isIsland ? IslandVisualStyle.primaryText : .primary
    }

    private var secondaryForeground: Color {
        isIsland ? IslandVisualStyle.secondaryText : .secondary
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if isIsland {
                    IslandModuleHeader(title: "Clipboard History", subtitle: nil, systemImage: "doc.on.clipboard")
                } else {
                    Label("Clipboard History", systemImage: "doc.on.clipboard").font(.headline)
                }
                Spacer(minLength: 4)
                if settings.clipboardHistoryEnabled {
                    Button {
                        settings.clipboardHistoryPaused.toggle()
                        history.updateRecording()
                    } label: {
                        Image(systemName: settings.clipboardHistoryPaused ? "play.fill" : "pause.fill")
                            .frame(width: 26, height: 26)
                    }
                    .help(settings.clipboardHistoryPaused ? Text("Resume Recording") : Text("Pause Recording"))
                    .accessibilityLabel(settings.clipboardHistoryPaused ? Text("Resume Recording") : Text("Pause Recording"))
                }
                Button { confirmsClear = true } label: {
                    Image(systemName: "trash").frame(width: 26, height: 26)
                }
                .disabled(history.entries.isEmpty && history.errorMessage == nil)
                .help(Text("Clear Clipboard History…"))
                .accessibilityLabel("Clear Clipboard History…")
            }
            .buttonStyle(.borderless)

            HStack {
                if isIsland {
                    Toggle("Record Clipboard", isOn: $settings.clipboardHistoryEnabled)
                        .toggleStyle(IslandClipboardToggleStyle())
                } else {
                    Toggle("Record Clipboard", isOn: $settings.clipboardHistoryEnabled)
                        .toggleStyle(.switch).controlSize(.small).tint(.accentColor)
                }
                Spacer()
                Text(settings.clipboardHistoryPaused && settings.clipboardHistoryEnabled
                     ? String(localized: "Paused") : "\(history.entries.filter { !$0.isFavorite }.count) / \(settings.clipboardHistoryEntryLimit)")
                    .font(.caption.monospacedDigit()).foregroundStyle(secondaryForeground)
            }
            .onChange(of: settings.clipboardHistoryEnabled) { _, _ in history.updateRecording() }

            if let error = history.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let notice = history.noticeMessage {
                Text(notice).font(.caption).foregroundStyle(secondaryForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass").foregroundStyle(secondaryForeground) }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command)
                    .help(Text("Search Clipboard History")).accessibilityLabel("Search Clipboard History")
                TextField("Search Clipboard History", text: $query)
                    .textFieldStyle(.plain).foregroundStyle(primaryForeground)
                    .focused($searchFocused)
                    .onKeyPress(.escape) { query = ""; searchFocused = false; return .handled }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help(Text("Clear Search"))
                        .accessibilityLabel("Clear Search")
                }
            }
            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Picker("Content Type", selection: $filter) {
                ForEach(ClipboardContentFilter.allCases) { value in Text(value.title).tag(value) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            if history.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if history.filteredEntries(query: query, filter: filter).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(secondaryForeground)
                    Text(query.isEmpty ? String(localized: "No Clipboard History") : String(localized: "No Results"))
                        .font(.callout).foregroundStyle(secondaryForeground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(history.filteredEntries(query: query, filter: filter)) { entry in
                            ClipboardHistoryRow(isIsland: isIsland, entry: entry,
                                                onPreview: { preview = entry })
                            Divider()
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }

            HStack {
                Text("Saved on this Mac").font(.caption2).foregroundStyle(secondaryForeground)
                Spacer()
                Picker("Keep History", selection: $settings.clipboardHistoryRetentionDays) {
                    Text("1 Day").tag(1)
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .accessibilityLabel("Keep History")
                .onChange(of: settings.clipboardHistoryRetentionDays) { _, _ in history.prune(force: true) }
            }
        }
        .foregroundStyle(primaryForeground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            history.prune(force: true)
            if !isIsland { searchFocused = true }
        }
        .alert("Clear Clipboard History?", isPresented: $confirmsClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { history.clear() }
        } message: {
            Text("This removes saved history from this Mac, not the current clipboard or shelf items.")
        }
        .sheet(item: $preview) { entry in
            VStack(spacing: 12) {
                ScrollView {
                    switch entry.content {
                    case .text(let value), .url(let value):
                        Text(verbatim: value).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let data, _):
                        if let image = ClipboardHistoryRow.thumbnail(data, maximumSize: 900) {
                            Image(nsImage: image).resizable().scaledToFit()
                        }
                    }
                }
                HStack {
                    Button("Close") { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Copy") { history.copy(entry) }.keyboardShortcut(.defaultAction)
                }
            }
            .foregroundStyle(primaryForeground)
            .padding(20).frame(width: 440, height: 320)
        }
    }
}


private struct ClipboardHistoryRow: View {
    let isIsland: Bool
    @Environment(ClipboardHistoryStore.self) private var history
    let entry: ClipboardHistoryEntry
    let onPreview: () -> Void

    private var secondaryForeground: Color {
        isIsland ? IslandVisualStyle.secondaryText : .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPreview) {
                Group {
                    switch entry.content {
                    case .image(let data, _):
                        if let image = Self.thumbnail(data, maximumSize: 96) {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else { Image(systemName: "photo") }
                    case .text: Image(systemName: "doc.text")
                    case .url: Image(systemName: "link")
                    }
                }
                .frame(width: 36, height: 36)
            }
            .help(Text("View Clipboard Item")).accessibilityLabel("View Clipboard Item")
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.content.searchText.isEmpty ? String(localized: "Image") : String(entry.content.searchText.prefix(500)))
                    .font(.system(size: 12)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.copiedAt, style: .relative).font(.caption2).foregroundStyle(secondaryForeground)
            }
            .contentShape(Rectangle()).onTapGesture(count: 2) { history.copy(entry) }
            Button { history.setFavorite(!entry.isFavorite, id: entry.id) } label: {
                Image(systemName: entry.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(entry.isFavorite ? Color.yellow : secondaryForeground)
                    .frame(width: 24, height: 28)
            }
            .help(entry.isFavorite ? Text("Remove Favorite") : Text("Add Favorite"))
            .accessibilityLabel(entry.isFavorite ? Text("Remove Favorite") : Text("Add Favorite"))
            Button { history.copy(entry) } label: {
                Image(systemName: "doc.on.doc").frame(width: 24, height: 28)
            }
            .help(Text("Copy")).accessibilityLabel("Copy")
            Button { history.addToShelf(entry) } label: {
                Image(systemName: "tray.and.arrow.down").frame(width: 24, height: 28)
            }
            .disabled(history.onAddToShelf == nil)
            .help(Text("Add to Shelf")).accessibilityLabel("Add to Shelf")
            Button { history.remove(entry.id) } label: {
                Image(systemName: "xmark").frame(width: 24, height: 28)
            }
            .help(Text("Delete Clipboard Item")).accessibilityLabel("Delete Clipboard Item")
        }
        .buttonStyle(.borderless).padding(.vertical, 6).frame(height: 66)
    }

    static func thumbnail(_ data: Data, maximumSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
