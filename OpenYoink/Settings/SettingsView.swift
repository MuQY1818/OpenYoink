import AppKit
import Combine
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SettingsNavigationModel {
    var selectedPane: SettingsPane = .general
}

/// Settings window (S8): native sidebar navigation with grouped forms. The
/// sidebar keeps all five destinations readable in Chinese and at larger text
/// sizes without crowding the title bar. All user-visible strings are
/// LocalizedStringKey literals,
/// resolved through Localizable.xcstrings (S10); runtime-computed fallbacks
/// use `String(localized:)` explicitly.
///
/// Presented via the SwiftUI `Settings` scene (`OpenYoinkApp`); opened from
/// the menu bar (`MenuBarController.showSettings`). `SettingsStore` and
/// `HotKeyMonitor` arrive through the environment.
struct SettingsView: View {
    @Environment(SettingsNavigationModel.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        HStack(spacing: 0) {
            List(selection: $navigation.selectedPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                        .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 156, idealWidth: 168, maxWidth: 188)
            .accessibilityLabel("Settings Categories")

            Divider()

            selectedContent(for: navigation.selectedPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("settings.content.\(navigation.selectedPane.rawValue)")
        }
        .frame(
            minWidth: 680,
            idealWidth: 720,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 520,
            maxHeight: .infinity
        )
    }

    @ViewBuilder
    private func selectedContent(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsTab()
        case .triggers:
            TriggerSettingsTab()
        case .ignoredApps:
            IgnoredAppsSettingsTab()
        case .storage:
            StorageSettingsTab()
        case .about:
            AboutSettingsTab()
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case triggers
    case ignoredApps
    case storage
    case about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .triggers: "Triggers"
        case .ignoredApps: "Ignored Apps"
        case .storage: "Storage"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .triggers: "keyboard"
        case .ignoredApps: "hand.raised"
        case .storage: "externaldrive"
        case .about: "info.circle"
        }
    }
}

// MARK: - Storage and recovery

private struct StorageSettingsTab: View {
    @Environment(StorageManagementController.self) private var storage
    @State private var snapshotToRestore: PersistenceController.RecoverySnapshot?
    @State private var pendingImportToDiscard: PendingImportJournal.Record?
    @State private var confirmsDiscard = false

    var body: some View {
        Form {
            Section("Managed Storage") {
                LabeledContent("Materialized files") {
                    Text(ByteCountFormatter.string(
                        fromByteCount: storage.materializedBytes,
                        countStyle: .file
                    ))
                    .monospacedDigit()
                }

                HStack {
                    Button("Clean Up Unused Files") { storage.cleanUnusedFiles() }
                        .disabled(!storage.canCleanUnusedFiles)
                    Button("Show Data Folder") { storage.revealDataFolder() }
                }

                if !storage.canCleanUnusedFiles {
                    Text("Cleanup is disabled while recovery data needs attention.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Pending Imports") {
                if storage.isPendingImportRecoveryDamaged {
                    Label("Pending import recovery data needs manual attention. Automatic cleanup is disabled.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if storage.pendingImports.isEmpty {
                    Text("No received files are waiting to be imported.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(storage.pendingImports) { pending in
                        HStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pending.displayName)
                                    .lineLimit(2)
                                Text(pending.createdAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Retry Import") {
                                storage.retryPendingImport(pending)
                            }
                            .accessibilityIdentifier("storage.pendingImport.retry")

                            Button(role: .destructive) {
                                pendingImportToDiscard = pending
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete Pending Import")
                            .accessibilityIdentifier("storage.pendingImport.delete")
                        }
                    }

                    Text("These files are retained in OpenYoink's managed storage until you retry or delete them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recovery") {
                if storage.snapshots.isEmpty {
                    Text("No recovery data is available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(storage.snapshots) { snapshot in
                        HStack(spacing: 10) {
                            Image(systemName: snapshot.isRecoverable
                                  ? "clock.arrow.circlepath"
                                  : "exclamationmark.triangle")
                                .foregroundStyle(snapshot.isRecoverable ? Color.secondary : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.kind == .lastKnownGood
                                     ? "Last Known Good Shelf"
                                     : "Quarantined Shelf Data")
                                HStack(spacing: 6) {
                                    if let date = snapshot.modifiedAt {
                                        Text(date, style: .date)
                                        Text(date, style: .time)
                                    }
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: snapshot.byteCount,
                                        countStyle: .file
                                    ))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if snapshot.isRecoverable {
                                Button("Restore…") { snapshotToRestore = snapshot }
                            } else {
                                Text("Manual repair required")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("Delete All Recovery Data…", role: .destructive) {
                        confirmsDiscard = true
                    }
                }

                if let message = storage.statusMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let error = storage.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { storage.refresh() }
        .alert("Restore Shelf Data?", isPresented: Binding(
            get: { snapshotToRestore != nil },
            set: { if !$0 { snapshotToRestore = nil } }
        )) {
            Button("Cancel", role: .cancel) { snapshotToRestore = nil }
            Button("Restore") {
                if let snapshot = snapshotToRestore { storage.restore(snapshot) }
                snapshotToRestore = nil
            }
        } message: {
            Text("The current shelf will be preserved as a backup before the selected snapshot is restored.")
        }
        .alert("Delete All Recovery Data?", isPresented: $confirmsDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { storage.discardAllRecoveryData() }
        } message: {
            Text("This removes OpenYoink's recovery snapshots. Files currently on the shelf are not deleted.")
        }
        .alert("Delete Pending Import?", isPresented: Binding(
            get: { pendingImportToDiscard != nil },
            set: { if !$0 { pendingImportToDiscard = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingImportToDiscard = nil }
            Button("Delete", role: .destructive) {
                if let pending = pendingImportToDiscard {
                    storage.discardPendingImport(pending)
                }
                pendingImportToDiscard = nil
            }
        } message: {
            Text("This permanently deletes OpenYoink's retained copy. The source application may no longer be able to provide it again.")
        }
    }
}

// MARK: - General


// MARK: - Triggers

private struct TriggerSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HotKeyMonitor.self) private var hotKeyMonitor

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Side Shelf Reveal") {
                Toggle("Preview side shelf on hover", isOn: $settings.classicShelfHoverRevealEnabled)
                    .disabled(!settings.classicShelfEnabled)
                Text("Drag the edge tab to reposition it. File drag reveal is configured below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Island Reveal") {
                Toggle("Expand Island on hover", isOn: $settings.islandHoverRevealEnabled)
                    .disabled(!settings.islandEnabled)
                Toggle("Expand Island when dragging files near the top", isOn: $settings.islandDragApproachEnabled)
                    .disabled(!settings.islandEnabled)
                    .accessibilityIdentifier("settings.islandDragApproach")
                Text("Top drag reveal is off by default to keep browser tabs unobstructed. Clicking Island always works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Global Hot Key") {
                Toggle("Enable", isOn: $settings.hotKeyEnabled)

                LabeledContent("Shortcut") {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(shortcut: $settings.hotKeyShortcut)
                        Button("Restore Default") {
                            settings.hotKeyShortcut = .default
                        }
                        .disabled(settings.hotKeyShortcut == .default)
                    }
                }

                // UX3: 双击保存剪贴板。开启时单击带一个识别窗的延迟 —— 脚注
                // 说明此取舍；关闭即恢复零延迟单击。
                Toggle("Double-press saves clipboard", isOn: $settings.hotKeyDoublePressSavesClipboard)
                    .disabled(!settings.hotKeyEnabled)
                Text("When enabled, a single press toggles the shelf after a brief delay (0.3 s) so a double press can be recognized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = hotKeyMonitor.registrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // UX1/2: 拖拽自动出现（Yoink 核心交互）。三档单控：立即出现 /
            // 拖到贴边唤出 / 无动作。边缘灵敏度沿用旧边缘触发的三档设置。
            Section("When Dragging Files") {
                Picker("When Dragging Files", selection: $settings.dragAutoAppearMode) {
                    Text("Show immediately").tag(SettingsStore.DragAutoAppearMode.immediate)
                    Text("Show at screen edge").tag(SettingsStore.DragAutoAppearMode.edgeOnly)
                    Text("Do nothing").tag(SettingsStore.DragAutoAppearMode.off)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Picker("Sensitivity", selection: $settings.edgeTriggerSensitivity) {
                    Text("Low").tag(TriggerSensitivity.low)
                    Text("Medium").tag(TriggerSensitivity.medium)
                    Text("High").tag(TriggerSensitivity.high)
                }
                .disabled(settings.dragAutoAppearMode != .edgeOnly)

                Text(dragModeFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Drag triggers stay silent while an ignored app is frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mouse Shake") {
                Toggle("Shake the mouse to show the shelf", isOn: $settings.shakeTriggerEnabled)
                Picker("Sensitivity", selection: $settings.shakeSensitivity) {
                    Text("Low").tag(TriggerSensitivity.low)
                    Text("Medium").tag(TriggerSensitivity.medium)
                    Text("High").tag(TriggerSensitivity.high)
                }
                .disabled(!settings.shakeTriggerEnabled)
            }
        }
        .formStyle(.grouped)
    }

    /// UX1/2: 随模式变化的说明文案（immediate 无需贴边；edgeOnly 在 custom
    /// 位置下不可用）。
    private var dragModeFootnote: String {
        switch settings.dragAutoAppearMode {
        case .immediate:
            String(localized: "The shelf appears at its configured position as soon as you start dragging — no need to reach the screen edge.")
        case .edgeOnly:
            String(localized: "While dragging, hold the cursor at the shelf's screen edge for a moment to reveal it. Not available in custom position mode.")
        case .off:
            String(localized: "The shelf won't appear automatically while dragging.")
        }
    }
}

// MARK: - Ignored Apps

private struct IgnoredAppsSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selection: Set<String> = []
    @State private var runningApps: [NSRunningApplication] = []

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(settings.ignoredAppBundleIDs, id: \.self) { bundleID in
                        IgnoredAppRow(bundleID: bundleID).tag(bundleID)
                    }
                }
                .frame(minHeight: 160)
                .onDeleteCommand {
                    settings.removeIgnoredApps(bundleIDs: selection)
                    selection.removeAll()
                }

                HStack {
                    Menu("Add…") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button {
                                if let bundleID = app.bundleIdentifier {
                                    settings.addIgnoredApp(bundleID: bundleID)
                                }
                            } label: {
                                Label {
                                    Text(app.localizedName ?? app.bundleIdentifier ?? String(localized: "Unknown"))
                                } icon: {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Choose Application…") { chooseApplication() }
                    }
                    .fixedSize()

                    Spacer()

                    Button("Remove") {
                        settings.removeIgnoredApps(bundleIDs: selection)
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                }
            } header: {
                Text("Ignored Apps")
            } footer: {
                Text("Shake and drag triggers stay silent while one of these apps is frontmost. The global hot key is never filtered.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadRunningApps() }
    }

    private func reloadRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// NSOpenPanel on /Applications — sandbox-legal because the user picks the
    /// app explicitly (user-selected read entitlement).
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.addIgnoredApp(bundleID: bundleID)
    }
}

/// One ignore-list entry: app icon, display name, bundle identifier. Icon and
/// name resolve through NSWorkspace even when the app isn't running; an app
/// that can no longer be located degrades to a dashed placeholder + raw ID.
private struct IgnoredAppRow: View {
    let bundleID: String

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var displayName: String {
        guard let appURL else { return bundleID }
        let bundle = Bundle(url: appURL)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    @Environment(SupportController.self) private var support
    @State private var didCopyDiagnostics = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: versionString)
                LabeledContent("License", value: "MIT")
            }

            Section("Acknowledgments") {
                Text("Open-Yoink is an independent clean-room implementation crafted for macOS. Bundled third-party components are Sparkle (MIT) for updates and mediaremote-adapter (BSD 3-Clause) for the optional local Now Playing module. A complete attribution record is available in THIRD_PARTY_NOTICES.md in the source repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Support") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { supportButtons }
                    VStack(alignment: .leading, spacing: 8) { supportButtons }
                }
                Text("Diagnostics include only the app version, macOS, architecture, and relevant setting states. They never include file names, paths, clipboard data, shelf contents, or user identifiers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var supportButtons: some View {
        Button("Usage Help") { support.openHelp() }
            .accessibilityIdentifier("settings.support.help")
        Button("Report an Issue…") { support.reportIssue() }
            .accessibilityIdentifier("settings.support.report")
        Button(didCopyDiagnostics
               ? String(localized: "Copied")
               : String(localized: "Copy Diagnostic Summary")) {
            didCopyDiagnostics = support.copyDiagnosticSummary()
        }
        .accessibilityIdentifier("settings.support.copyDiagnostics")
    }
}
