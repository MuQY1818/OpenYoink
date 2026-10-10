import Foundation

enum WorkflowPreset: String, CaseIterable, Identifiable {
    case files, clipboard, toolbox
    var id: Self { self }
    var title: String {
        switch self {
        case .files: String(localized: "File Shelf")
        case .clipboard: String(localized: "Files & Clipboard")
        case .toolbox: String(localized: "Full Toolbox")
        }
    }
    var detail: String {
        switch self {
        case .files: String(localized: "Use the side shelf for files. Island and its background modules are turned off.")
        case .clipboard: String(localized: "Enable the side shelf and Island with Shelf, Transfers and Clipboard History. Recording stays under your control.")
        case .toolbox: String(localized: "Enable all built-in Island modules. Clipboard recording stays under your control.")
        }
    }
}

extension SettingsStore {
    /// Changes presentation only. Data, privacy consent, shortcut, and unknown module IDs survive.
    func applyWorkflowPreset(_ preset: WorkflowPreset) {
        classicShelfEnabled = true
        edgeTabEnabled = true
        dragAutoAppearMode = .edgeOnly
        islandDragApproachEnabled = false
        islandHoverRevealEnabled = false
        classicShelfHoverRevealEnabled = false
        islandEnabled = preset != .files
        let builtIns: [IslandModuleID] = [.shelf, .transfers, .timer, .battery, .system, .media, .folders, .clipboard]
        let enabled: [IslandModuleID]
        let pinned: [IslandModuleID]
        switch preset {
        case .files: enabled = [.shelf, .transfers]; pinned = [.shelf]
        case .clipboard: enabled = [.shelf, .transfers, .clipboard]; pinned = [.shelf, .clipboard]
        case .toolbox: enabled = builtIns; pinned = [.shelf, .clipboard, .folders, .media, .system]
        }
        let unknownEnabled = islandModuleConfiguration.enabledModuleIDs.filter { !builtIns.contains($0) }
        let unknownPinned = islandModuleConfiguration.pinnedModuleIDs.filter { !builtIns.contains($0) }
        islandModuleConfiguration = IslandModuleConfiguration(enabledModuleIDs: enabled + unknownEnabled,
                                                               pinnedModuleIDs: Array((unknownPinned + pinned).prefix(5)))
    }
}
