import AppKit
import SwiftUI

struct IslandModuleLibraryLayout {
    enum Category: CaseIterable, Identifiable {
        case files, productivity, system

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .files: "Files & Clipboard"
            case .productivity: "Productivity"
            case .system: "System"
            }
        }

        init(moduleID: IslandModuleID) {
            switch moduleID {
            case .shelf, .transfers, .folders, .clipboard: self = .files
            case .battery, .system: self = .system
            default: self = .productivity
            }
        }
    }

    let pinned: [IslandModuleDescriptor]
    private let unpinned: [IslandModuleDescriptor]

    init(descriptors: [IslandModuleDescriptor], pinnedIDs: [IslandModuleID]) {
        pinned = pinnedIDs.compactMap { id in descriptors.first { $0.id == id } }
        let pinnedSet = Set(pinnedIDs)
        unpinned = descriptors.filter { !pinnedSet.contains($0.id) }.sorted { $0.order < $1.order }
    }

    func modules(in category: Category) -> [IslandModuleDescriptor] {
        unpinned.filter { Category(moduleID: $0.id) == category }
    }
}

struct IslandModuleLibraryView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(IslandModuleRegistry.self) private var registry
    @Environment(AIUsageModuleStore.self) private var aiUsage

    let onOpenModule: (IslandModuleID) -> Void
    let onOpenSettings: () -> Void

    private static let dragPrefix = "com.weijue.OpenYoink.island-pin:"

    var body: some View {
        let ids = settings.islandModuleConfiguration.pinnedModuleIDs
        let layout = IslandModuleLibraryLayout(descriptors: registry.descriptors, pinnedIDs: ids)

        VStack(spacing: 10) {
            IslandModuleHeader(
                title: "Module Library",
                subtitle: String(localized: "\(ids.count) of \(IslandModuleConfiguration.maximumPinnedModules) positions pinned"),
                systemImage: "square.grid.2x2"
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if !layout.pinned.isEmpty {
                        heading("Pinned")
                        ForEach(layout.pinned) { descriptor in
                            pinnedRow(descriptor)
                        }
                    }
                    ForEach(IslandModuleLibraryLayout.Category.allCases) { category in
                        let modules = layout.modules(in: category)
                        if !modules.isEmpty {
                            heading(category.title)
                            ForEach(modules) { descriptor in
                                moduleRow(descriptor, pinned: false)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Open Full Settings") { onOpenSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(IslandVisualStyle.secondaryText)
            .padding(.top, 5)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func pinnedRow(_ descriptor: IslandModuleDescriptor) -> some View {
        moduleRow(descriptor, pinned: true)
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first, payload.hasPrefix(Self.dragPrefix) else { return false }
                let source = IslandModuleID(rawValue: String(payload.dropFirst(Self.dragPrefix.count)))
                return movePinned(source, to: descriptor.id)
            }
    }

    private func movePinned(_ sourceID: IslandModuleID, to destinationID: IslandModuleID) -> Bool {
        let ids = settings.islandModuleConfiguration.pinnedModuleIDs
        guard let source = ids.firstIndex(of: sourceID),
              let destination = ids.firstIndex(of: destinationID),
              source != destination else { return false }
        settings.movePinnedIslandModules(fromOffsets: IndexSet(integer: source),
                                         toOffset: destination > source ? destination + 1 : destination)
        return true
    }

    private func moduleRow(_ descriptor: IslandModuleDescriptor, pinned: Bool) -> some View {
        let enabled = settings.isIslandModuleEnabled(descriptor.id)
        let pinnedCount = settings.islandModuleConfiguration.pinnedModuleIDs.count
        let pinLimit = pinnedCount >= IslandModuleConfiguration.maximumPinnedModules
        let pinLabel: LocalizedStringKey = pinned ? "Unpin module" : "Pin module"
        let status: LocalizedStringKey = !enabled ? "Disabled" : pinned ? "Pinned" : "Enabled"

        return HStack(spacing: 10) {
            if pinned {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(IslandVisualStyle.secondaryText)
                    .frame(width: 20, height: 26)
                    .contentShape(Rectangle())
                    .draggable(Self.dragPrefix + descriptor.id.rawValue)
                    .help(Text("Reorder pinned module"))
                    .accessibilityHidden(true)
                    .contextMenu {
                        let pins = settings.islandModuleConfiguration.pinnedModuleIDs
                        if let index = pins.firstIndex(of: descriptor.id) {
                            if index > pins.startIndex {
                                Button("Move Earlier") { _ = movePinned(descriptor.id, to: pins[index - 1]) }
                            }
                            if index + 1 < pins.endIndex {
                                Button("Move Later") { _ = movePinned(descriptor.id, to: pins[index + 1]) }
                            }
                        }
                    }
            }

            Image(systemName: descriptor.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.accentColor : Color.white.opacity(0.42))
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(IslandVisualStyle.secondaryText)
                if enabled, let hint = availabilityHint(for: descriptor.id) {
                    Label(hint, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(IslandVisualStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            if enabled {
                Button("Open") { onOpenModule(descriptor.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption.weight(.semibold))
            }

            Button {
                settings.setIslandModulePinned(!pinned, id: descriptor.id)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || (!pinned && pinLimit))
            .opacity(!enabled || (!pinned && pinLimit) ? 0.34 : 1)
            .help(Text(!pinned && pinLimit ? "All pin positions are in use" : pinLabel))
            .accessibilityLabel(Text(pinLabel))

            Toggle(isOn: Binding(
                get: { settings.isIslandModuleEnabled(descriptor.id) },
                set: { settings.setIslandModuleEnabled($0, id: descriptor.id) }
            )) {
                Text(descriptor.title)
            }
            .labelsHidden()
            .accessibilityLabel(Text(descriptor.title))
            .toggleStyle(IslandClipboardToggleStyle())
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 42)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(pinned ? 0.085 : 0.045))
        }
        .accessibilityActions {
            let pins = settings.islandModuleConfiguration.pinnedModuleIDs
            if pinned, let index = pins.firstIndex(of: descriptor.id) {
                if index > pins.startIndex {
                    Button("Move Earlier") { _ = movePinned(descriptor.id, to: pins[index - 1]) }
                }
                if index + 1 < pins.endIndex {
                    Button("Move Later") { _ = movePinned(descriptor.id, to: pins[index + 1]) }
                }
            }
        }
    }

    private func availabilityHint(for id: IslandModuleID) -> String? {
        if id == .clipboard, !settings.clipboardHistoryEnabled {
            return String(localized: "Clipboard recording is off")
        }
        if id == .aiUsage {
            switch aiUsage.status {
            case .idle: return String(localized: "Requires TokenTracker")
            case .notRunning: return String(localized: "TokenTracker isn't running")
            case .failed: return String(localized: "Can't read TokenTracker")
            case .loading, .ready: break
            }
        }
        return nil
    }
}
