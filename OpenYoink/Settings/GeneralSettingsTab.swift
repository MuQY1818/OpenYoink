import AppKit
import Combine
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(ClipboardHistoryStore.self) private var history
    @Environment(SettingsStore.self) private var settings
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(UpdateController.self) private var updateController
    @State private var islandScreens: [IslandScreenCatalog.Option] = []
    @State private var pendingPreset: WorkflowPreset?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Workflow Presets") {
                Menu("Apply a Preset…") {
                    ForEach(WorkflowPreset.allCases) { preset in
                        Button(preset.title) { pendingPreset = preset }
                    }
                }
                Text("Presets change modules and reveal behavior. Your files, history and recording choice are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch OpenYoink at login", isOn: Binding(
                    get: { launchAtLoginController.isRequested },
                    set: { launchAtLoginController.setRequested($0) }
                ))
                .disabled(!launchAtLoginController.isAvailable)

                if launchAtLoginController.requiresApproval {
                    HStack {
                        Label("Approval is required in System Settings.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") {
                            launchAtLoginController.openSystemSettings()
                        }
                    }
                } else if let error = launchAtLoginController.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !launchAtLoginController.isAvailable {
                    Text("Login item registration is unavailable for this copy of the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Side Shelf") {
                Toggle("Enable Side Shelf", isOn: $settings.classicShelfEnabled)

                if settings.classicShelfEnabled {
                    Picker("Position", selection: $settings.shelfPosition) {
                        Text("Left").tag(SettingsStore.ShelfPosition.left)
                        Text("Right").tag(SettingsStore.ShelfPosition.right)
                        Text("Custom").tag(SettingsStore.ShelfPosition.custom)
                    }
                    .pickerStyle(.segmented)
                }

                if settings.classicShelfEnabled && settings.shelfPosition == .custom {
                    // S9: custom 模式 —— 面板可拖动，拖动结束持久化 frame；
                    // 首次选中从右缘默认位置起步。边缘触发在无贴附缘时暂停。
                    Text("Drag the shelf by its title bar to place it anywhere. The edge trigger is unavailable in custom mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.classicShelfEnabled {
                    LabeledContent("Width") {
                        HStack(spacing: 8) {
                            Slider(value: $settings.shelfWidth, in: 240...480, step: 10)
                            Text("\(Int(settings.shelfWidth)) pt")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }

                    Toggle("Hide after dragging out", isOn: $settings.autoHide)

                    Toggle("Keep expanded after dropping", isOn: $settings.keepShelfOpenAfterDrop)
                    Text("Applies only to the side shelf opened automatically during a drag. Drag-out and empty-shelf settings still apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // UX6: 非空→空迁移时自动收回（手动唤出的空架不受影响）。
                    Toggle("Hide automatically when empty", isOn: $settings.autoHideWhenEmpty)

                    // EdgeTab: 拉环只在 shelf 隐藏时贴屏幕边缘显示（互斥模型；
                    // shelf 展开后由面板外缘隐形热区承担同点位收起）。
                    // custom 模式无贴附缘，开关不生效（说明文案覆盖）。
                    Toggle("Show edge tab while shelf is hidden", isOn: $settings.edgeTabEnabled)
                    Text("Click the tab to show the shelf, drag it along the edge to reposition, or drop files onto it. Not shown in custom position mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Shelf Behavior") {
                if settings.classicShelfEnabled && settings.islandEnabled {
                    Text("With Side Shelf enabled, the shelf shortcut controls it. Otherwise the shortcut opens Island Shelf.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("After dragging out", selection: $settings.dragOutRemovalPolicy) {
                    Text("Keep on Shelf").tag(SettingsStore.DragOutRemovalPolicy.keep)
                    Text("Remove").tag(SettingsStore.DragOutRemovalPolicy.remove)
                    Text("Ask Every Time").tag(SettingsStore.DragOutRemovalPolicy.ask)
                }
                .accessibilityIdentifier("settings.dragOutRemovalPolicy")

                // F-05: 双模式拖入说明（静态文案）。
                Text("Dropping files keeps a reference. Hold ⌘ while dropping to move the original into the shelf — the original goes to the Trash, so it can be restored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("After a successful drop, the receiving shelf stays open so you can drag the item to its destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenYoink Island") {
                Toggle("Enable OpenYoink Island", isOn: $settings.islandEnabled)

                if settings.islandEnabled {
                    Text("Island uses the built-in camera housing when available. Displays without a notch use a floating pill below the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Display", selection: $settings.islandDisplayTarget) {
                        Text("Main Display")
                            .tag(SettingsStore.IslandDisplayTarget.main)
                        Text("Follow Pointer")
                            .tag(SettingsStore.IslandDisplayTarget.automatic)
                        ForEach(islandScreens) { screen in
                            Text(islandScreenTitle(screen))
                                .tag(SettingsStore.IslandDisplayTarget.display(screen.id))
                        }
                        if case let .display(id) = settings.islandDisplayTarget,
                           !islandScreens.contains(where: { $0.id == id }) {
                            Text("Unavailable Display")
                                .tag(SettingsStore.IslandDisplayTarget.display(id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("settings.islandDisplay")

                    Text(islandDisplayDescription)
                        .font(.caption)
                        .foregroundStyle(isSelectedIslandDisplayUnavailable
                                         ? Color.orange : Color.secondary)

                    Text("Configure side shelf and Island reveal behavior in Triggers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if settings.islandEnabled {
                Section("Island Modules") {
                    islandModuleControl("Shelf", id: .shelf)
                    Text("The Island Shelf and Side Shelf use the same items. Turning this module off never deletes them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    islandModuleControl("Transfers", id: .transfers)
                    islandModuleControl("Timer", id: .timer)
                    islandModuleControl("Battery", id: .battery)
                    if settings.isIslandModuleEnabled(.battery) {
                        Toggle("Notify when fully charged",
                               isOn: $settings.islandFullChargeAlertEnabled)
                    }

                    islandModuleControl("System Status", id: .system)
                    Text("System status is read-only and never terminates apps, cleans disks, controls fans, or reads private sensors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    islandModuleControl("Now Playing", id: .media)
                    Text("Shows artwork and controls from the active media player. Processing stays on this Mac; compatibility can vary after macOS updates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    islandModuleControl("Quick Access", id: .folders)
                    islandModuleControl("Clipboard History", id: .clipboard)

                    Text("Open the Island module library to drag the five pinned positions into order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Clipboard History") {
                Toggle("Record Clipboard", isOn: $settings.clipboardHistoryEnabled)
                    .onChange(of: settings.clipboardHistoryEnabled) { _, _ in history.updateRecording() }
                Toggle("Pause Recording", isOn: $settings.clipboardHistoryPaused)
                    .disabled(!settings.clipboardHistoryEnabled)
                    .onChange(of: settings.clipboardHistoryPaused) { _, _ in history.updateRecording() }
                Picker("Keep History", selection: $settings.clipboardHistoryRetentionDays) {
                    Text("1 Day").tag(1)
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                }
                .onChange(of: settings.clipboardHistoryRetentionDays) { _, _ in history.prune(force: true) }
                Picker("History Limit", selection: $settings.clipboardHistoryEntryLimit) {
                    ForEach(ClipboardHistoryPolicy.supportedEntryLimits, id: \.self) { Text("\($0)").tag($0) }
                }
                .onChange(of: settings.clipboardHistoryEntryLimit) { _, _ in history.prune(force: true) }
                LabeledContent("History Shortcut") { ShortcutRecorderView(shortcut: $settings.clipboardHistoryShortcut) }
                if let error = history.shortcutRegistrationError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Favorites do not expire. Up to 30 favorites and 20 MiB total are kept on this Mac. Privacy markers and ignored apps are skipped; unmarked sensitive text may still be recorded.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Turning recording off keeps saved history. Clear history to delete it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clipboard History…") { history.onShowWindow?() }
            }

            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    Text("System").tag(SettingsStore.LanguagePreference.system)
                    Text("English").tag(SettingsStore.LanguagePreference.english)
                    Text("中文").tag(SettingsStore.LanguagePreference.chinese)
                }
                .accessibilityIdentifier("settings.language")
                // S10: AppleLanguages 覆盖在启动最早期应用（AppDelegate.
                // applicationWillFinishLaunching），运行期切换故需重启生效。
                Text("Takes effect after relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Sparkle: 自动检查更新（应用唯一的联网行为；手动检查在菜单栏菜单）。
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $settings.autoUpdateCheckEnabled)
                Text("Update checks contact GitHub Pages and releases only; nothing else uses the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .error(let message) = updateController.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Download Latest Release…") {
                        updateController.openManualDownloadPage()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLoginController.refresh() }
        .alert("Apply Workflow Preset?", isPresented: Binding(
            get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingPreset = nil }
            Button("Apply") {
                if let preset = pendingPreset { settings.applyWorkflowPreset(preset) }
                pendingPreset = nil
            }
        } message: {
            Text(pendingPreset?.detail ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginController.refresh()
        }
        .onAppear {
            refreshIslandScreens()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            refreshIslandScreens()
        }
    }

    private func islandModuleControl(
        _ title: LocalizedStringKey,
        id: IslandModuleID
    ) -> some View {
        let enabled = settings.isIslandModuleEnabled(id)
        let pinned = settings.isIslandModulePinned(id)
        let pinnedCount = settings.islandModuleConfiguration.pinnedModuleIDs.count
        return HStack {
            Toggle(title, isOn: Binding(
                get: { settings.isIslandModuleEnabled(id) },
                set: { settings.setIslandModuleEnabled($0, id: id) }
            ))
            Spacer()
            Button {
                settings.setIslandModulePinned(!pinned, id: id)
            } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .disabled(!enabled || (!pinned && pinnedCount >= 5))
        }
    }

    private func refreshIslandScreens() {
        islandScreens = IslandScreenCatalog.options()
    }

    private func islandScreenTitle(_ screen: IslandScreenCatalog.Option) -> String {
        guard screen.isMain else { return screen.name }
        return "\(screen.name) · \(String(localized: "Current Main"))"
    }

    private var isSelectedIslandDisplayUnavailable: Bool {
        guard case let .display(id) = settings.islandDisplayTarget else {
            return false
        }
        return !islandScreens.contains(where: { $0.id == id })
    }

    private var islandDisplayDescription: String {
        switch settings.islandDisplayTarget {
        case .main:
            String(localized: "Island stays on the display chosen as main in System Settings.")
        case .automatic:
            String(localized: "Island follows the pointer and active drag across displays.")
        case .display where isSelectedIslandDisplayUnavailable:
            String(localized: "This display is unavailable. Island is temporarily using the main display and will return when it reconnects.")
        case .display:
            String(localized: "Island stays on this display until you choose another.")
        }
    }
}
