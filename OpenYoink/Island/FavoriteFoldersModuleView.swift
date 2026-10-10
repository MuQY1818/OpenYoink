import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FavoriteFoldersModuleView: View {
    @Environment(FavoriteFoldersStore.self) private var store
    @Environment(FavoriteFolderDropCoordinator.self) private var copyCoordinator
    @Environment(DropTargetState.self) private var dropTargetState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var addPanel: NSOpenPanel?
    @State private var isAddButtonHovering = false
    @State private var renameTargetID: UUID?
    @State private var renameText = ""

    private let columns = [
        GridItem(.flexible(minimum: 120), spacing: 8),
        GridItem(.flexible(minimum: 120), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 10) {
            IslandModuleHeader(
                title: "Quick Access",
                subtitle: headerSubtitle,
                systemImage: "folder"
            )
            .overlay(alignment: .trailing) {
                Button(action: chooseFolders) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 30, height: 30)
                        .background {
                            Circle()
                                .fill(Color.accentColor.opacity(isAddButtonHovering ? 1 : 0.9))
                                .overlay {
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                                }
                                .shadow(
                                    color: Color.accentColor.opacity(isAddButtonHovering ? 0.45 : 0.3),
                                    radius: isAddButtonHovering ? 6 : 4,
                                    y: 2
                                )
                        }
                        .contentShape(Circle())
                        .scaleEffect(isAddButtonHovering ? 1.06 : 1)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isAddButtonHovering = hovering
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14),
                           value: isAddButtonHovering)
                .accessibilityLabel(Text("Add folders"))
                .help(Text("Add folders"))
            }

            if let noticeMessage = store.noticeMessage {
                notice(message: noticeMessage, isError: store.noticeIsError)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                Text("Drop a folder here to add a favorite")
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(IslandVisualStyle.secondaryText)
            .padding(8)
            .background(copyCoordinator.target == .addFavorite ? IslandVisualStyle.selectedFill : IslandVisualStyle.cardFill,
                        in: RoundedRectangle(cornerRadius: 7))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { copyCoordinator.addFrame = $0 }

            if copyCoordinator.isCopying {
                HStack(spacing: 8) {
                    ProgressView(value: Double(copyCoordinator.completed), total: Double(max(1, copyCoordinator.total)))
                    Text("\(copyCoordinator.completed) / \(copyCoordinator.total)").font(.caption.monospacedDigit())
                    Button("Cancel") { copyCoordinator.cancelCopy() }.buttonStyle(.plain)
                }
            } else if let message = copyCoordinator.message {
                Text(message).font(.caption).foregroundStyle(IslandVisualStyle.secondaryText).lineLimit(2)
            }

            if store.items.isEmpty {
                IslandEmptyState(
                    title: "No favorite folders",
                    message: "Add folders you open often.",
                    systemImage: "folder.badge.plus"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(store.items) { item in
                            FavoriteFolderTile(
                                item: item,
                                isSelected: store.selectedID == item.id,
                                isUnavailable: store.isUnavailable(item.id),
                                onRename: {
                                    renameText = item.displayName
                                    renameTargetID = item.id
                                }
                            )
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                copyCoordinator.tileFrames[item.id] = $0
                            }
                            .onDisappear { copyCoordinator.tileFrames.removeValue(forKey: item.id) }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.automatic)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { copyCoordinator.viewport = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(2)
        .onDisappear {
            copyCoordinator.tileFrames.removeAll()
            copyCoordinator.viewport = .zero
            copyCoordinator.addFrame = .zero
            copyCoordinator.resetTarget()
        }
        .overlay {
            if dropTargetState.isTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    }
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16),
                   value: store.noticeMessage)
        .alert("Rename Favorite", isPresented: renameAlertPresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {
                renameTargetID = nil
            }
            Button("Save") {
                if let renameTargetID {
                    store.rename(renameTargetID, to: renameText)
                }
                renameTargetID = nil
            }
        }
    }

    private var headerSubtitle: String {
        if store.items.isEmpty { return String(localized: "Favorite folders") }
        return String(localized: "Favorite folders") + " · \(store.items.count)"
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renameTargetID != nil },
            set: { presented in
                if !presented { renameTargetID = nil }
            }
        )
    }

    private func notice(message: String, isError: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                store.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.055))
        }
    }

    private func chooseFolders() {
        guard addPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Folders to Quick Access")
        panel.prompt = String(localized: "Add")
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        addPanel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            Task { @MainActor in
                addPanel = nil
                guard response == .OK else { return }
                _ = store.addFolders(panel.urls)
            }
        }
    }
}

private struct FavoriteFolderTile: View {
    @Environment(FavoriteFoldersStore.self) private var store
    @Environment(FavoriteFolderDropCoordinator.self) private var copyCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    @State private var activePanel: NSOpenPanel?

    let item: FavoriteFolder
    let isSelected: Bool
    let isUnavailable: Bool
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isUnavailable ? "folder.badge.questionmark" : "folder.fill")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(isUnavailable ? Color.orange : Color.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isUnavailable
                     ? String(localized: "Unavailable")
                     : item.parentDisplayName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(isUnavailable ? Color.orange.opacity(0.88)
                                     : IslandVisualStyle.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
        .background(tileBackground)
        .overlay(tileBorder)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.13)) { isHovering = hovering }
            }
        }
        .gesture(clickGesture)
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let sourceRawValue = values.first,
                  let sourceID = UUID(uuidString: sourceRawValue) else { return false }
            store.move(sourceID, before: item.id)
            return true
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.displayName))
        .accessibilityValue(Text(isUnavailable ? "Unavailable" : item.parentDisplayName))
        .accessibilityHint(Text("Double-click to open"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(Text(item.lastKnownPath))
    }

    private var clickGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { result in
                NSApp.currentEvent?.window?.makeKey()
                switch result {
                case .first:
                    store.select(item.id)
                    _ = store.open(item.id)
                case .second:
                    store.select(item.id)
                }
            }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected || copyCoordinator.target == .folder(item.id)
                  ? IslandVisualStyle.selectedFill
                  : Color.white.opacity(isHovering ? 0.075 : 0.045))
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
                isUnavailable ? Color.orange.opacity(0.42)
                    : isSelected || copyCoordinator.target == .folder(item.id) ? Color.accentColor.opacity(0.62)
                    : IslandVisualStyle.hairline,
                lineWidth: 1
            )
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open") {
            store.select(item.id)
            _ = store.open(item.id)
        }

        Menu("Open With") {
            let applications = store.applicationURLs(for: item.id)
            let defaultApplication = store.defaultApplicationURL(for: item.id)
            ForEach(applications, id: \.self) { applicationURL in
                Button {
                    _ = store.open(item.id, with: applicationURL)
                } label: {
                    Text(applicationName(
                        applicationURL,
                        isDefault: applicationURL == defaultApplication
                    ))
                }
            }
            if applications.isEmpty {
                Text("No compatible applications")
            }
            Divider()
            Button("Choose Application…") { chooseApplication() }
        }

        Divider()
        Button("Rename…", action: onRename)
        Button("Locate Again…") { locateAgain() }
        Divider()
        Button("Remove Favorite", role: .destructive) {
            store.remove(item.id)
        }
    }

    private func applicationName(_ url: URL, isDefault: Bool) -> String {
        let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return isDefault ? name + " " + String(localized: "(Default)") : name
    }

    private func chooseApplication() {
        guard activePanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an Application")
        panel.prompt = String(localized: "Open")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        activePanel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            Task { @MainActor in
                activePanel = nil
                guard response == .OK, let applicationURL = panel.url else { return }
                _ = store.open(item.id, with: applicationURL)
            }
        }
    }

    private func locateAgain() {
        guard activePanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Locate Favorite Folder")
        panel.prompt = String(localized: "Reconnect")
        panel.allowedContentTypes = [.folder]
        panel.directoryURL = URL(fileURLWithPath: item.lastKnownPath, isDirectory: true)
            .deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        activePanel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            Task { @MainActor in
                activePanel = nil
                guard response == .OK, let url = panel.url else { return }
                _ = store.relocate(item.id, to: url)
            }
        }
    }
}
