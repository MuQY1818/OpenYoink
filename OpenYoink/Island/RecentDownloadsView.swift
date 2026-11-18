import AppKit
import SwiftUI

struct RecentDownloadsView: View {
    @Environment(RecentDownloadsStore.self) private var downloads
    @Environment(ShelfStore.self) private var shelf
    @State private var panel: NSOpenPanel?
    @State private var refreshID = UUID()
    @State private var feedback: LocalizedStringKey?

    private struct RefreshKey: Equatable {
        let folder: Data?
        let id: UUID
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(downloads.folderURL?.lastPathComponent ?? String(localized: "Recent Downloads"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if downloads.bookmark != nil {
                    action("arrow.clockwise", label: "Refresh Downloads") {
                        feedback = nil
                        refreshID = UUID()
                    }
                    .disabled(downloads.phase == .loading)
                }
                Menu {
                    Button("Choose Folder…", action: chooseFolder)
                    if downloads.bookmark != nil {
                        Button("Forget Folder") {
                            feedback = nil
                            downloads.forgetFolder()
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .fixedSize()
                .help(Text("Downloads Folder"))
                .accessibilityLabel(Text("Downloads Folder"))
            }
            .padding(.horizontal, 4)

            if let feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(IslandVisualStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            switch downloads.phase {
            case .needsFolder:
                emptyState("No folder selected", icon: "folder.badge.plus", canChooseFolder: true)
            case .loading:
                ProgressView().controlSize(.small)
                    .accessibilityLabel(Text("Loading Downloads"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                emptyState("Downloads folder unavailable", icon: "exclamationmark.triangle", canChooseFolder: true)
            case .ready:
                if downloads.entries.isEmpty {
                    emptyState("No completed downloads", icon: "arrow.down.circle", canChooseFolder: false)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(downloads.entries) { file in row(file) }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: RefreshKey(folder: downloads.bookmark, id: refreshID)) {
            await downloads.refresh()
        }
    }

    private func row(_ file: RecentDownload) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.lastPathComponent)
                if file.date != .distantPast {
                    Text(file.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(IslandVisualStyle.secondaryText)
                }
            }
            Spacer(minLength: 4)
            action("arrow.up.right.square", label: "Open Download") {
                feedback = downloads.withFile(file, { NSWorkspace.shared.open($0) }) == true
                    ? nil : "Could Not Open Download"
            }
            action("folder", label: "Reveal in Finder") {
                let revealed = downloads.withFile(file) {
                    NSWorkspace.shared.activateFileViewerSelecting([$0])
                    return true
                }
                feedback = revealed == true ? nil : "Download No Longer Available"
            }
            action("tray.and.arrow.down", label: "Add Download to Shelf") {
                guard let item = try? downloads.makeShelfItem(file) else {
                    feedback = "Could Not Add Download to Shelf"
                    return
                }
                shelf.add(item)
                feedback = "Added to Shelf"
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 40)
        .background(IslandVisualStyle.cardFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func action(_ icon: String, label: LocalizedStringKey,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private func emptyState(_ title: LocalizedStringKey, icon: String, canChooseFolder: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 21))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .accessibilityHidden(true)
            Text(title).font(.callout.weight(.semibold))
            if canChooseFolder {
                Button("Choose Folder…", action: chooseFolder).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFolder() {
        guard panel == nil else { return }
        let picker = NSOpenPanel()
        picker.title = String(localized: "Choose Downloads Folder")
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = false
        picker.directoryURL = downloads.folderURL
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel = picker
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { response in
            Task { @MainActor in
                panel = nil
                guard response == .OK, let url = picker.url else { return }
                do {
                    try downloads.chooseFolder(url)
                    feedback = nil
                    refreshID = UUID()
                } catch {
                    feedback = "Could Not Save Folder Access"
                }
            }
        }
    }
}
