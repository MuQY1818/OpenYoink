import AppKit
import SwiftUI

struct IslandRootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ShelfStore.self) private var shelfStore
    @Environment(TransferStore.self) private var transferStore
    @Environment(IslandActivityCoordinator.self) private var coordinator
    @Environment(IslandModuleRegistry.self) private var registry
    @Environment(IslandModuleContainer.self) private var moduleContainer
    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(PowerSourceMonitor.self) private var powerMonitor
    @Environment(NowPlayingModuleStore.self) private var nowPlayingStore
    @Environment(SystemStatusModuleStore.self) private var systemStatusStore
    @Environment(AIUsageModuleStore.self) private var aiUsageStore
    @Environment(FavoriteFoldersStore.self) private var favoriteFoldersStore
    @Environment(ClipboardHistoryStore.self) private var clipboardHistoryStore
    @Environment(FavoriteFolderDropCoordinator.self) private var folderCopy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCompactHovering = false
    @State private var isCompactMediaControlHovering = false
    @State private var isCollapseControlHovering = false
    @State private var isSettingsControlHovering = false
    @State private var isSendingCompactMediaCommand = false
    @State private var mediaAccent = ArtworkAccent.fallback
    @State private var renderedSurfaceState: IslandSurfaceState = .compact
    @State private var activeSurfaceAnimation: UUID?
    @State private var requestedSurfaceTransitionID: UInt64 = 0
    @State private var isShowingModuleLibrary = false

    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            if renderedSurfaceState.isExpanded {
                expandedContent
                    .frame(width: coordinator.currentLayout?.expandedFrame.width,
                           height: coordinator.currentLayout?.expandedFrame.height,
                           alignment: .top)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: IslandSurfaceRevealModifier(
                                progress: 0,
                                opacity: 0.82,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            ),
                            identity: IslandSurfaceRevealModifier(
                                progress: 1,
                                opacity: 1,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            )
                        ),
                        removal: .modifier(
                            active: IslandSurfaceRevealModifier(
                                progress: 0,
                                opacity: 0,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            ),
                            identity: IslandSurfaceRevealModifier(
                                progress: 1,
                                opacity: 1,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            )
                        )
                    ))
            } else {
                floatingAwareCompactContent
                    // Upper bounds only: a fixed size here becomes the hosting
                    // window's minimum size, and the floating idle dot needs
                    // the panel to shrink below the pill (issue #11).
                    .frame(minWidth: 0,
                           maxWidth: coordinator.currentLayout?.compactFrame.width,
                           minHeight: 0,
                           maxHeight: coordinator.currentLayout?.compactFrame.height,
                           alignment: .top)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("island.root")
        .alert("File Already Exists", isPresented: Binding(
            get: { folderCopy.conflictName != nil },
            set: { if !$0 { folderCopy.decideConflict(.cancel) } }
        )) {
            Button("Keep Both") { folderCopy.decideConflict(.keepBoth) }
            Button("Skip") { folderCopy.decideConflict(.skip) }
            Button("Cancel Copy", role: .cancel) { folderCopy.decideConflict(.cancel) }
        } message: {
            Text((folderCopy.conflictName ?? "") + "\n" + String(localized: "The existing file will not be overwritten."))
        }
        .onChange(of: coordinator.surfaceTransitionID, initial: true) {
            renderSurface(coordinator.surfaceState)
        }
        .onChange(of: settings.islandModuleConfiguration, initial: true) {
            registry.apply(settings: settings)
            moduleContainer.apply(
                configuration: settings.islandModuleConfiguration,
                isActive: settings.islandEnabled
            )
            if !registry.isEnabled(coordinator.selectedModule),
               let fallback = visibleModuleDescriptors.first?.id
                    ?? registry.enabledDescriptors.first?.id {
                coordinator.selectedModule = fallback
            }
        }
        .onChange(of: nowPlayingStore.snapshot?.artworkData, initial: true) { _, data in
            mediaAccent = ArtworkAccentExtractor.accent(from: data)
        }
        .onChange(of: coordinator.selectedModule) { samplingContextChanged() }
        .onChange(of: coordinator.surfaceState) { samplingContextChanged() }
    }

    private func renderSurface(_ state: IslandSurfaceState) {
        requestedSurfaceTransitionID = coordinator.surfaceTransitionID
        if reduceMotion {
            activeSurfaceAnimation = nil
            renderedSurfaceState = state
            coordinator.completeSurfaceTransition(requestedSurfaceTransitionID)
            return
        }
        guard renderedSurfaceState != state else {
            // A coalesced close/open/close may leave the same fold running.
            // Its real completion must still precede the host-window resize.
            if activeSurfaceAnimation == nil {
                coordinator.completeSurfaceTransition(requestedSurfaceTransitionID)
            }
            return
        }
        let animationID = UUID()
        activeSurfaceAnimation = animationID
        withAnimation(surfaceAnimation(for: state), completionCriteria: .removed) {
            renderedSurfaceState = state
        } completion: {
            guard activeSurfaceAnimation == animationID else { return }
            activeSurfaceAnimation = nil
            coordinator.completeSurfaceTransition(requestedSurfaceTransitionID)
        }
    }

    private func surfaceAnimation(for state: IslandSurfaceState) -> Animation {
        if state.isExpanded {
            return .smooth(
                duration: IslandMotion.expandContentDuration,
                extraBounce: 0
            )
        }
        return .smooth(
            duration: IslandMotion.collapseContentDuration,
            extraBounce: 0
        )
    }

    private func samplingContextChanged() {
        NotificationCenter.default.post(name: .openYoinkResourcePolicyDidChange, object: nil)
        if coordinator.surfaceState.isExpanded, coordinator.selectedModule == .media {
            nowPlayingStore.refresh()
        }
    }

    private var collapsedSurfaceHeight: CGFloat {
        coordinator.currentLayout?.compactFrame.height
            ?? IslandGeometryResolver.floatingCompactSize.height
    }

    private var collapsedSurfaceWidth: CGFloat {
        coordinator.currentLayout?.compactFrame.width
            ?? IslandGeometryResolver.floatingCompactSize.width
    }

    /// Displays without a notch can shrink the idle pill into a dot or hide
    /// it entirely (issue #11). The window controller sizes the panel.
    private var floatingAwareCompactContent: some View {
        let presentation = hasPhysicalNotch ? .capsule : coordinator.floatingPresentation
        return ZStack(alignment: .top) {
            switch presentation {
            case .capsule:
                compactContent
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.5, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.08, anchor: .top))
                    ))
            case .dot:
                floatingIdleDot
                    .transition(.opacity.combined(with: .scale(scale: 0.3, anchor: .top)))
            case .hidden:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: presentation)
    }

    private var floatingIdleDot: some View {
        let activity = coordinator.primaryActivity()
        let ring = activity?.moduleID == .media ? mediaAccent.color : activityTint(activity)
        let diameter = IslandGeometryResolver.floatingDotDiameter
        return Circle()
            .fill(Color.black.opacity(0.92))
            .overlay {
                Circle().strokeBorder(ring.opacity(activity == nil ? 0.32 : 0.75), lineWidth: 1)
            }
            .frame(width: diameter, height: diameter)
            .padding(.top, (IslandGeometryResolver.floatingDotHitSize.height - diameter) / 2)
            .accessibilityElement()
            .accessibilityLabel(Text(compactAccessibilityLabel))
            .accessibilityHint(Text("Open OpenYoink Island"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { coordinator.show(module: defaultOpenModule) }
    }

    private var compactContent: some View {
        ZStack {
            Button {
                coordinator.show(module: defaultOpenModule)
            } label: {
                if hasPhysicalNotch {
                    physicalNotchCompactContent
                } else {
                    HStack(spacing: 8) {
                        compactLeading
                        compactSummary
                        Spacer(minLength: 4)
                        compactTrailing
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(compactAccessibilityLabel))
            .accessibilityHint(Text("Open OpenYoink Island"))
            .help(Text("Open OpenYoink Island"))

            compactMediaTransportOverlay
        }
        // The panel keeps a transparent strip below the real camera housing so
        // clicking remains easy. Only the content above draws pixels.
        .contentShape(Rectangle())
        .background {
            if !hasPhysicalNotch {
                compactSurfaceShape
                    .fill(Color.black.opacity(0.94))
            }
        }
        .overlay {
            if !hasPhysicalNotch && compactIsHighlighted {
                compactSurfaceShape
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            } else if !hasPhysicalNotch {
                compactSurfaceShape
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
        }
        .onHover { hovering in
            if reduceMotion {
                isCompactHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    isCompactHovering = hovering
                }
            }
        }
    }

    private var physicalNotchCompactContent: some View {
        ZStack(alignment: .top) {
            Color.clear
            IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11)
                .fill(Color.black)
                .frame(height: coordinator.currentLayout?.topInset ?? 32)
            HStack(spacing: 0) {
                compactLeading
                    .frame(width: IslandGeometryResolver.compactWingWidth)
                Spacer()
                    .frame(width: coordinator.currentLayout?.cameraHousingWidth ?? 0)
                compactTrailing
                    .frame(width: IslandGeometryResolver.compactWingWidth)
            }
            .frame(maxWidth: .infinity)
            .frame(height: coordinator.currentLayout?.topInset ?? 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var compactLeading: some View {
        let activity = coordinator.primaryActivity()
        if activity?.moduleID == .media,
           let data = nowPlayingStore.snapshot?.artworkData,
           let image = NSImage(data: data) {
            CompactNowPlayingArtworkView(
                image: image,
                tint: mediaAccent.color,
                isHovered: compactIsHighlighted
            )
                .id(nowPlayingStore.snapshot?.title)
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
        } else {
            Image(systemName: activity?.systemImage
                  ?? defaultModuleDescriptor?.systemImage
                  ?? "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activityTint(activity))
                .opacity(compactIsHighlighted || activity != nil ? 1 : 0.72)
                .accessibilityHidden(true)
        }
    }

    private var compactTrailing: some View {
        Group {
            if coordinator.primaryActivity()?.moduleID == .media,
               let snapshot = nowPlayingStore.snapshot {
                if nowPlayingStore.supportsTransportControls {
                    Color.clear.frame(width: 30, height: 22)
                } else {
                    IslandEqualizerView(
                        isPlaying: snapshot.isPlaying,
                        reduceMotion: reduceMotion,
                        tint: mediaAccent.color,
                        rhythmSeed: mediaRhythmSeed
                    )
                    .scaleEffect(0.92)
                }
            } else if transferStore.hasVisibleActivity && !reduceMotion {
                ProgressView()
                    .controlSize(.mini)
            } else if case .running = timerStore.state {
                Text(timerStore.formattedRemaining)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if let aiValue = aiUsageStore.compactValue {
                // Chosen in Settings: AI usage outranks the shelf count but
                // still yields to media, transfers and a running timer.
                Text(aiValue)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if registry.isEnabled(.shelf) {
                Text("\(shelfStore.items.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            } else if registry.isEnabled(.battery), powerMonitor.snapshot.hasBattery {
                Text("\(powerMonitor.snapshot.percentage)%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .opacity(compactIsHighlighted || coordinator.primaryActivity() != nil ? 1 : 0.72)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var compactMediaTransportOverlay: some View {
        if coordinator.primaryActivity()?.moduleID == .media,
           nowPlayingStore.snapshot != nil,
           nowPlayingStore.supportsTransportControls {
            if hasPhysicalNotch {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    compactMediaTransportButton
                        .frame(width: IslandGeometryResolver.compactWingWidth,
                               height: coordinator.currentLayout?.topInset ?? 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    compactMediaTransportButton
                        .frame(width: 44, height: 38)
                }
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var compactMediaTransportButton: some View {
        let snapshot = nowPlayingStore.snapshot
        let isPlaying = snapshot?.isPlaying == true
        let showsTransportControl = isCompactMediaControlHovering || compactIsHighlighted
        let actionLabel = isPlaying ? String(localized: "Pause") : String(localized: "Play")
        return Button {
            guard !isSendingCompactMediaCommand else { return }
            Task {
                isSendingCompactMediaCommand = true
                _ = await nowPlayingStore.send(.togglePlayPause)
                isSendingCompactMediaCommand = false
            }
        } label: {
            ZStack {
                IslandEqualizerView(
                    isPlaying: isPlaying,
                    reduceMotion: reduceMotion,
                    tint: mediaAccent.color,
                    rhythmSeed: mediaRhythmSeed
                )
                .scaleEffect(showsTransportControl ? 0.84 : 0.92)
                .opacity(showsTransportControl ? 0 : 1)

                Group {
                    if isSendingCompactMediaCommand {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(mediaAccent.color)
                    }
                }
                .frame(width: 30, height: 22)
                .background {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .overlay {
                            Capsule().strokeBorder(mediaAccent.color.opacity(0.38),
                                                   lineWidth: 0.75)
                        }
                }
                .scaleEffect(showsTransportControl ? 1 : 0.82)
                .opacity(showsTransportControl ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!nowPlayingStore.supportsTransportControls
                  || isSendingCompactMediaCommand)
        .opacity(nowPlayingStore.supportsTransportControls ? 1 : 0.46)
        .onHover { hovering in
            if reduceMotion {
                isCompactMediaControlHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    isCompactMediaControlHovering = hovering
                }
            }
        }
        .accessibilityLabel(Text(actionLabel))
        .accessibilityHint(Text("Control playback without expanding the Island"))
        .help(Text(actionLabel))
    }

    private var mediaRhythmSeed: UInt64 {
        guard let snapshot = nowPlayingStore.snapshot else { return 0 }
        return MusicVisualizerRhythm.seed(title: snapshot.title,
                                          artist: snapshot.artist,
                                          album: snapshot.album)
    }

    @ViewBuilder
    private var compactSummary: some View {
        if let activity = coordinator.primaryActivity() {
            VStack(alignment: .leading, spacing: 0) {
                Text(activity.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            if let aiSummary = aiUsageStore.compactSummary {
                Text(aiSummary)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
            } else if registry.isEnabled(.system),
               let cpu = systemStatusStore.snapshot.cpuUsage,
               let used = systemStatusStore.snapshot.memoryUsedBytes,
               let total = systemStatusStore.snapshot.memoryTotalBytes,
               total > 0 {
                Text("CPU \(Int((cpu * 100).rounded()))% · MEM \(Int((Double(used) / Double(total) * 100).rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            } else if registry.isEnabled(.folders),
                      coordinator.selectedModule == .folders {
                Text("Quick Access · \(favoriteFoldersStore.items.count)")
                    .font(.caption2.weight(.semibold))
            } else if registry.isEnabled(.clipboard), coordinator.selectedModule == .clipboard {
                Text(String(localized: "Clipboard History") + " · \(clipboardHistoryStore.entries.count)")
                    .font(.caption2.weight(.semibold))
            } else {
                Text(String(localized: "OpenYoink Island"))
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            if hasPhysicalNotch {
                physicalNotchModuleStrip
            } else {
                floatingIslandToolbar
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
            }
            moduleContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(coordinator.selectedModule)
                .clipped()
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .contentShape(expandedSurfaceShape)
        .background {
            ZStack {
                Color.black
                LinearGradient(
                    colors: [Color.white.opacity(0.035), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .clipShape(expandedSurfaceShape)
        }
        .overlay {
            if !hasPhysicalNotch {
                expandedSurfaceShape
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        // A physical notch is attached to the display rather than floating
        // above it, so an elevation shadow reads as a translucent rectangle.
        // Keep elevation only for the fallback pill on displays without a notch.
        .shadow(color: hasPhysicalNotch ? .clear : .black.opacity(0.30),
                radius: hasPhysicalNotch ? 0 : 16,
                y: hasPhysicalNotch ? 0 : 8)
        .contextMenu {
            Button("Settings…") {
                openSettings()
            }
            Button(pinLabel) {
                coordinator.setPinned(coordinator.surfaceState != .pinned)
            }
            Button("Collapse Island") {
                coordinator.collapse()
            }
        }
    }

    private var hasPhysicalNotch: Bool {
        coordinator.currentLayout?.hasPhysicalNotch == true
    }

    private var compactIsHighlighted: Bool {
        isCompactHovering || coordinator.isPointerHovering
    }

    private var compactSurfaceShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 13)
    }

    private var expandedSurfaceShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 26)
    }

    private var physicalNotchModuleStrip: some View {
        let slots = pinnedModuleSlots
        let leadingSlots = Array(slots.prefix(2))
        let trailingSlots = Array(slots.dropFirst(2))
        let notchWidth = coordinator.currentLayout?.cameraHousingWidth ?? 0
        let notchHeight = coordinator.currentLayout?.topInset ?? 32
        let stripHeight = notchHeight
            + IslandGeometryResolver.physicalNotchClickExtension

        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    settingsButton(size: 26)

                    ForEach(leadingSlots.indices, id: \.self) { index in
                        if let descriptor = leadingSlots[index] {
                            physicalNotchModuleButton(descriptor)
                        } else {
                            emptyModuleSlot(size: 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                Color.clear
                    .frame(width: notchWidth)
                    .allowsHitTesting(false)

                HStack(spacing: 2) {
                    ForEach(trailingSlots.indices, id: \.self) { index in
                        if let descriptor = trailingSlots[index] {
                            physicalNotchModuleButton(descriptor)
                        } else {
                            emptyModuleSlot(size: 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)

            // The hardware camera housing itself cannot receive mouse events.
            // Give its small visible chin an explicit, top-most collapse target
            // instead of relying on a background button underneath the module
            // tabs. This also prevents the adjacent media tab from stealing a
            // click intended for the center of the Island.
            Button {
                coordinator.collapse()
            } label: {
                VStack(spacing: 0) {
                    Color.clear.frame(height: notchHeight)
                    Capsule()
                        .fill(Color.white.opacity(isCollapseControlHovering ? 0.50 : 0.22))
                        .frame(width: 30, height: 3)
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .frame(width: notchWidth, height: stripHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if reduceMotion {
                    isCollapseControlHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        isCollapseControlHovering = hovering
                    }
                }
            }
            .accessibilityLabel(Text("Collapse Island"))
            .help(Text("Collapse Island"))
        }
        .frame(height: stripHeight)
    }

    private func physicalNotchModuleButton(
        _ descriptor: IslandModuleDescriptor
    ) -> some View {
        let isSelected = coordinator.selectedModule == descriptor.id
        let isEnabled = registry.isEnabled(descriptor.id)
        return Button {
            isShowingModuleLibrary = false
            coordinator.selectedModule = descriptor.id
        } label: {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.72))
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
                }
                .opacity(isEnabled || isSelected ? 1 : 0.46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(descriptor.title))
        .help(Text(descriptor.title))
        .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
    }

    private var floatingIslandToolbar: some View {
        HStack(spacing: 10) {
            settingsButton(size: 30)
            moduleNavigation
            Spacer(minLength: 4)

            Button {
                coordinator.setPinned(coordinator.surfaceState != .pinned)
            } label: {
                Image(systemName: coordinator.surfaceState == .pinned
                      ? "pin.fill" : "pin")
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(pinLabel))
            .help(Text(pinLabel))

            Button {
                coordinator.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Collapse Island"))
            .help(Text("Collapse Island"))
        }
        .frame(height: 38)
    }

    private func settingsButton(size: CGFloat) -> some View {
        Button {
            isShowingModuleLibrary.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: size == 30 ? 13 : 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isSettingsControlHovering ? 1 : 0.72))
                .frame(width: size, height: size)
                .background {
                    Circle().fill(Color.white.opacity(isSettingsControlHovering ? 0.14 : 0.07))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isSettingsControlHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    isSettingsControlHovering = hovering
                }
            }
        }
        .accessibilityLabel(Text("Module Library"))
        .help(Text("Module Library"))
    }

    private func openSettings() {
        // The Island panel intentionally sits above ordinary app windows.
        // Collapse it before presenting Settings so it cannot cover the
        // controls the user just asked to reach.
        coordinator.collapse()
        onOpenSettings?()
    }

    private var pinLabel: String {
        coordinator.surfaceState == .pinned
            ? String(localized: "Unpin Island")
            : String(localized: "Pin Island")
    }

    private var moduleNavigation: some View {
        HStack(spacing: 3) {
            ForEach(pinnedModuleSlots.indices, id: \.self) { index in
                if let descriptor = pinnedModuleSlots[index] {
                    floatingModuleButton(descriptor)
                } else {
                    emptyModuleSlot(size: 30)
                }
            }
        }
        .padding(4)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.34))
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
        }
    }

    /// The five saved positions are the only normal compact navigation slots.
    /// Enabled but unpinned modules remain available from the module library.
    private var visibleModuleDescriptors: [IslandModuleDescriptor] {
        settings.islandModuleConfiguration.pinnedModuleIDs.compactMap {
            registry.descriptor(for: $0)
        }
    }

    private var pinnedModuleSlots: [IslandModuleDescriptor?] {
        let descriptors = visibleModuleDescriptors.map(Optional.some)
        return descriptors + Array(
            repeating: nil,
            count: max(0, IslandModuleConfiguration.maximumPinnedModules
                       - descriptors.count)
        )
    }

    private func floatingModuleButton(
        _ descriptor: IslandModuleDescriptor
    ) -> some View {
        let isSelected = coordinator.selectedModule == descriptor.id
        let isEnabled = registry.isEnabled(descriptor.id)
        return Button {
            isShowingModuleLibrary = false
            coordinator.selectedModule = descriptor.id
        } label: {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                }
                .contentShape(Circle())
                .opacity(isEnabled || isSelected ? 1 : 0.46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(descriptor.title))
        .help(Text(descriptor.title))
        .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
    }

    private func emptyModuleSlot(size: CGFloat) -> some View {
        IslandEmptyModuleSlot(size: size) { moduleID in
            coordinator.selectedModule = moduleID
            isShowingModuleLibrary = false
        }
    }

    private var moduleContent: some View {
        Group {
            if isShowingModuleLibrary {
                IslandModuleLibraryView(
                    onOpenModule: { moduleID in
                        coordinator.selectedModule = moduleID
                        isShowingModuleLibrary = false
                    },
                    onOpenSettings: openSettings
                )
            } else {
                moduleContainer.contentView(
                    for: coordinator.selectedModule,
                    context: IslandModuleViewContext(
                        onPerformRecovery: onPerformRecovery
                    )
                )
            }
        }
    }

    private var compactAccessibilityLabel: String {
        if let activity = coordinator.primaryActivity() {
            return [activity.title, activity.detail].compactMap { $0 }.joined(separator: ", ")
        }
        if registry.isEnabled(.shelf) {
            return String(localized: "OpenYoink Island, \(shelfStore.items.count) shelf items")
        }
        return String(localized: "OpenYoink Island")
    }

    private var defaultModuleDescriptor: IslandModuleDescriptor? {
        if registry.isEnabled(coordinator.selectedModule) {
            return registry.descriptors.first { $0.id == coordinator.selectedModule }
        }
        return registry.enabledDescriptors.first
    }

    private var defaultOpenModule: IslandModuleID {
        if let activity = coordinator.primaryActivity(), registry.isEnabled(activity.moduleID) {
            return activity.moduleID
        }
        return defaultModuleDescriptor?.id ?? .transfers
    }

    private func activityTint(_ activity: IslandActivity?) -> Color {
        switch activity?.priority {
        case .criticalBattery: return .red
        case .systemWarning: return .orange
        case .timerFinished: return .orange
        case .transfer, .userDrag: return .accentColor
        default: return .white
        }
    }

}
