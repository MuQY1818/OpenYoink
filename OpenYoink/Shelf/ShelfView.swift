import AppKit
import SwiftUI

enum ShelfPresentationStyle: Sendable, Equatable {
    case classic
    case island
}

private struct ShelfPresentationStyleEnvironmentKey: EnvironmentKey {
    static let defaultValue: ShelfPresentationStyle = .classic
}

private struct ShelfSelectionModeEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ShelfFocusActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

private struct ShelfUserRemovalActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor (@MainActor () -> Void) -> Void)? { nil }
}

extension EnvironmentValues {
    var shelfUserRemovalAction: (@MainActor (@MainActor () -> Void) -> Void)? {
        get { self[ShelfUserRemovalActionEnvironmentKey.self] }
        set { self[ShelfUserRemovalActionEnvironmentKey.self] = newValue }
    }
    var shelfFocusAction: (@MainActor () -> Void)? {
        get { self[ShelfFocusActionEnvironmentKey.self] }
        set { self[ShelfFocusActionEnvironmentKey.self] = newValue }
    }
    var shelfSelectionMode: Bool {
        get { self[ShelfSelectionModeEnvironmentKey.self] }
        set { self[ShelfSelectionModeEnvironmentKey.self] = newValue }
    }
    var shelfPresentationStyle: ShelfPresentationStyle {
        get { self[ShelfPresentationStyleEnvironmentKey.self] }
        set { self[ShelfPresentationStyleEnvironmentKey.self] = newValue }
    }
}

private struct ShelfActionStripReveal: ViewModifier, @MainActor Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(width: 130 * max(0, min(1, progress)), alignment: .trailing)
            .clipped()
            .opacity(progress)
    }
}

private struct ShelfIconButtonStyle: ButtonStyle {
    var active = false
    var expanded = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        HoverContent(configuration: configuration, active: active,
                     expanded: expanded, destructive: destructive)
    }

    private struct HoverContent: View {
        let configuration: Configuration
        let active: Bool
        let expanded: Bool
        let destructive: Bool
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(foregroundColor)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.14) :
                              expanded ? Color.primary.opacity(0.07) : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(isEnabled && configuration.isPressed ? 0.16 :
                                                           isEnabled && isHovering ? 0.09 : 0))
                        }
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovering)
        }

        private var foregroundColor: Color {
            guard isEnabled else { return Color.primary.opacity(0.25) }
            if active { return .accentColor }
            if destructive && (isHovering || configuration.isPressed) { return .red }
            return Color.primary.opacity(isHovering ? 0.95 : 0.72)
        }
    }
}

struct ShelfView: View {
    let presentationStyle: ShelfPresentationStyle

    init(presentationStyle: ShelfPresentationStyle = .classic) {
        self.presentationStyle = presentationStyle
    }

    @Environment(ShelfStore.self) private var store

    @Environment(DropTargetState.self) private var dropTargetState
    /// Custom placement, and persisting the frame after a drag.
    @Environment(SettingsStore.self) private var settings
    /// Keeps an open preview in step with the selection.
    @Environment(\.quickLookCoordinator) private var quickLookCoordinator
    @Environment(\.shelfFileServices) private var fileServices
    /// Card frames, shared by the marquee and drop insertion.
    @Environment(ShelfGridGeometry.self) private var gridGeometry
    @Environment(ShelfNoticeModel.self) private var notices
    @Environment(\.shelfRevealState) private var reveal
    /// runtime-only asynchronous batch status.
    @Environment(TransferStore.self) private var transferStore
    @Environment(ShelfInteractionState.self) private var interaction
    @Environment(\.accessibilityAnnouncementCenter) private var announcementCenter
    /// unavailable-item actions (external reconnect vs managed recovery).
    @Environment(\.itemRecoveryController) private var itemRecoveryController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    /// The collapse handle's action; nil (previews) does nothing.
    @Environment(\.shelfHideAction) private var shelfHideAction
    @Environment(\.shelfFocusAction) private var shelfFocusAction
    @Environment(\.shelfUserRemovalAction) private var shelfUserRemovalAction
    @State private var showsManagementActions = false
    @FocusState private var searchFocused: Bool

    /// Cards appearing and making room.
    static let cardAnimation = Animation.spring(response: 0.35, dampingFraction: 0.7)
    static let cornerRadius: CGFloat = 16
    static let gridSpacing: CGFloat = 12
    /// 84 pt so cards clear the collapse handle (10 pt + 2 pt gap); matches
    /// `ShelfLayoutEngine.gridColumnMinimum`.
    static let columnWidth: CGFloat = 84

    var body: some View {
        presentedSurface
            .environment(\.shelfSelectionMode, interaction.isSelecting)
            .environment(\.colorScheme, presentationStyle == .classic
                         ? (settings.appearance.theme.colorScheme ?? systemColorScheme) : .dark)
            .environment(\.shelfPresentationStyle, presentationStyle)
            .onChange(of: store.items) {
                dropTargetState.reset()
                interaction.normalize(for: store.visibleItems)
                if store.items.isEmpty { interaction.isSelecting = false }
            }
            .onChange(of: store.searchQuery) { normalizeSearch() }
            .onChange(of: store.contentFilter) { normalizeSearch() }
            .onChange(of: transferStore.currentTask, initial: true) { _, task in
                announcementCenter?.announce(task: task)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shelf.root")
    }

    @ViewBuilder
    private var presentedSurface: some View {
        if presentationStyle == .classic {
            ShelfInteractiveGlassSurface(appearance: settings.appearance,
                                         onBackgroundTap: clearSelectionAndCollapse) {
                Color.clear
                    .overlay { content }
                    .overlay { dropTargetHighlight }
                    .overlay { expandedStackOverlay }
                    .overlay(alignment: .top) { noticeBanner }
                    .overlay(alignment: .bottom) { dropModeHint }
            }
            .animation(reduceMotion ? nil : Self.cardAnimation,
                       value: interaction.expandedStackID)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: notices.message != nil)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: transferStore.hasVisibleActivity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: dropTargetState.mode)
            .padding(8)
            // The invisible outer collapse zone attaches *after* the padding, in the
            // window's content space: the tab sat on the panel's outer 14 pt, and
            // before the padding the shape's 8 pt inset shifted it and clicks missed.
            .overlay(alignment: outerCollapseStripAlignment == .trailing ? .topTrailing : .topLeading) {
                outerCollapseStrip
            }
        } else {
            Color.clear
                .overlay { content }
                .overlay { dropTargetHighlight }
                .overlay { expandedStackOverlay }
                .overlay(alignment: .top) { noticeBanner }
                .overlay(alignment: .bottom) { dropModeHint }
                .animation(reduceMotion ? nil : Self.cardAnimation,
                           value: interaction.expandedStackID)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                           value: notices.message != nil)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                           value: transferStore.hasVisibleActivity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                           value: dropTargetState.mode)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 4) {
            if presentationStyle == .classic {
                header
            }
            searchControls
            // No transfer strip while a shelf drag is in flight: inserting it
            // re-lays out the grid and clears card geometry mid-reorder, which
            // makes the insertion line fall back to "append to the end".
            if transferStore.hasVisibleActivity, transferStore.dragSessionsInFlight == 0 {
                ShelfActivityStrip(onPerformRecovery: performRecovery)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top)))
            }
            if store.items.isEmpty {
                ShelfEmptyState()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: clearSelectionAndCollapse)
            } else if store.visibleItems.isEmpty {
                Text("No Results").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: clearSelectionAndCollapse)
            } else {
                itemGrid
            }
            if shouldShowTopLevelQuickActions {
                ShelfQuickActionBar(items: topLevelActionItems)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(8)
        .background {

            if presentationStyle != .classic {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: clearSelectionAndCollapse)
            }
        }
    }

    /// Shelf name and item count ("selected/total" with a selection). In custom
    /// placement the whole bar is a `WindowDragHandle` with a grip symbol; the
    /// final frame is persisted to `customShelfFrame`.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if isCustomPosition {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text("Drag to move"))
            }
            if collapseHandleSide == .trailing {
                collapseButton(side: .trailing)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
            Text("Shelf")
                .font(.headline)
            Spacer()
            Text(countCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if collapseHandleSide == .leading {
                collapseButton(side: .leading)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .overlay {
            if isCustomPosition {
                WindowDragHandle { frame in
                    settings.customShelfFrame = frame
                }
            }
        }
    }

    private var isCustomPosition: Bool {
        settings.shelfPosition == .custom
    }

    private var searchControls: some View {
        @Bindable var store = store
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                .keyboardShortcut("f", modifiers: .command)
                .help(Text("Search Shelf")).accessibilityLabel("Search Shelf")
                TextField("Search Shelf", text: $store.searchQuery)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onKeyPress(.escape) { store.searchQuery = ""; searchFocused = false; return .handled }
                if !store.searchQuery.isEmpty {
                    Button { store.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                        .help(Text("Clear Search")).accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // a soft capsule that sits *in* the glass instead of a
            // flat grey slab on top of it.
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(searchFocused ? 0.09 : 0.06))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(searchFocused ? 0.14 : 0.07),
                                          lineWidth: 0.5)
                    }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: searchFocused)
            HStack {
                Picker("Content Type", selection: $store.contentFilter) {
                    ForEach(ShelfContentFilter.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().controlSize(.small)
                Spacer(minLength: 2)
                managementMenu
            }
        }.font(.caption).buttonStyle(.plain)
    }

    private var visibleSelection: Set<UUID> {
        store.selection.intersection(Set(store.visibleItems.map(\.id)))
    }

    private var managementMenu: some View {
        HStack(spacing: 0) {
            if showsManagementActions {
                HStack(spacing: 0) {
                    managementAction("Batch Selection", symbol: interaction.isSelecting ? "checkmark.circle.fill" : "checkmark.circle",
                                     identifier: "shelf.selection.toggle", enabled: !store.items.isEmpty,
                                     active: interaction.isSelecting) {
                        setSelectionMode(!interaction.isSelecting)
                    }
                    managementAction(allVisibleItemsSelected ? "Deselect All" : "Select All",
                                     symbol: allVisibleItemsSelected ? "checkmark.rectangle.stack.fill" : "checkmark.rectangle.stack",
                                     identifier: "shelf.selection.all", enabled: !store.visibleItems.isEmpty) {
                        if allVisibleItemsSelected {
                            store.clearSelection()
                        } else {
                            setSelectionMode(true)
                            store.selectAllVisible()
                        }
                    }
                    managementDivider
                    managementAction("Remove Selected", symbol: "trash",
                                     identifier: "shelf.selection.remove", enabled: !visibleSelection.isEmpty,
                                     destructive: true) {
                        removeShelfItems(ids: visibleSelection)
                    }
                    managementAction("Clear Shelf", symbol: "xmark.bin",
                                     identifier: "shelf.clear", enabled: !store.items.isEmpty,
                                     destructive: true) {
                        removeShelfItems(ids: Set(store.items.map(\.id)))
                    }
                    managementDivider
                    managementAction("Undo Remove", symbol: "arrow.uturn.backward",
                                     identifier: "shelf.undoRemoval", enabled: store.canUndoRemoval) {
                        _ = store.undoLastRemoval()
                    }
                }
                .fixedSize()
                .transition(.modifier(active: ShelfActionStripReveal(progress: 0),
                                      identity: ShelfActionStripReveal(progress: 1)))
                .allowsHitTesting(showsManagementActions)
                .accessibilityHidden(!showsManagementActions)
            }
            Button {
                shelfFocusAction?()
                showsManagementActions.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ShelfIconButtonStyle(active: interaction.isSelecting,
                                              expanded: showsManagementActions))
            .help(Text("Manage Shelf"))
            .accessibilityLabel("Manage Shelf")
            .accessibilityIdentifier("shelf.manage")

        }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88),
                   value: showsManagementActions)
    }

    private var managementDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 12)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private func managementAction(_ title: LocalizedStringKey, symbol: String,
                                  identifier: String, enabled: Bool, active: Bool = false,
                                  destructive: Bool = false, help: LocalizedStringKey? = nil,
                                  action: @escaping () -> Void) -> some View {
        Button {
            searchFocused = false
            shelfFocusAction?()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(ShelfIconButtonStyle(active: active, destructive: destructive))
        .disabled(!enabled)
        .help(Text(help ?? title))
        .accessibilityLabel(Text(title))
        .accessibilityValue(active ? Text("Selected") : Text(""))
        .accessibilityIdentifier(identifier)
    }

    private func setSelectionMode(_ enabled: Bool) {
        if enabled {
            collapseStack()
            shelfFocusAction?()
        }
        interaction.isSelecting = enabled
        if !enabled { store.clearSelection() }
    }

    private var allVisibleItemsSelected: Bool {
        !store.visibleItems.isEmpty && visibleSelection.count == store.visibleItems.count
    }

    private func removeShelfItems(ids: Set<UUID>) {
        let remove: @MainActor () -> Void = {
            do {
                let removed = try store.removeBatchForUser(ids: ids)
                guard !removed.isEmpty else { return }
                interaction.normalize(for: store.visibleItems)
                quickLookCoordinator?.refreshPreview(contextItem: nil)
                notices.show(String(localized: "Removed from Shelf. Undo with ⌘Z, or recover in Settings → Storage."))
            } catch {
                notices.show(String(localized: "Could not save a recovery copy. Nothing was removed."))
            }
        }
        if let shelfUserRemovalAction {
            shelfUserRemovalAction(remove)
        } else {
            remove()
        }
    }

    private func normalizeSearch() {
        let visible = store.visibleItems
        store.setSelection(store.selection.intersection(Set(visible.map(\.id))))
        interaction.normalize(for: visible)
        gridGeometry.cardFrames = gridGeometry.cardFrames.filter { frame in visible.contains { $0.id == frame.key } }
        dropTargetState.reset()
    }

    private var countCaption: String {
        store.selection.isEmpty
            ? "\(store.items.count)"
            : String(localized: "\(store.selection.count) of \(store.items.count)")
    }

    // MARK: - Grid

    private var itemGrid: some View {
        GeometryReader { viewport in
            // Derive the column count once for this viewport so the scrolling
            // and non-scrolling grid agree; `adaptive` used to drop to two
            // columns inside the slightly narrower scroll container.
            let gridColumns = Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: Self.gridSpacing),
                count: ShelfLayoutEngine.gridColumnCount(for: viewport.size.width)
            )
            let fits = presentationStyle == .classic
                && ShelfLayoutEngine.gridFits(itemCount: store.visibleItems.count,
                                              viewport: viewport.size)
            Group {
                if fits {
                    cardGrid(columns: gridColumns)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    scrollingGrid(columns: gridColumns)
                }
            }
            // The grid container keeps the pre-selection bounds for a few frames
            // while the quick-action row animates in, so it swallows clicks on
            // the empty area below the cards. Treat a tap here as a background
            // tap; card clicks are owned by their AppKit event layer.
            .contentShape(Rectangle())
            .onTapGesture(perform: clearSelectionAndCollapse)
            // Change the container immediately; do not keep an outgoing grid
            // alive with the same card IDs and shared drag/selection geometry.
            .animation(nil, value: fits)
        }
    }

    private func scrollingGrid(columns: [GridItem]) -> some View {
        ScrollView(.vertical) {
            cardGrid(columns: columns)
        }
        .scrollIndicators(.hidden)
    }

    private func cardGrid(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
            ForEach(store.visibleItems) { item in
                gridCell(for: item)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Self.cardAnimation, value: store.items)
        .animation(reduceMotion ? nil : Self.cardAnimation, value: store.selection)
    }

    private func gridCell(for item: ShelfItem) -> some View {
        let index = store.index(ofItemWithID: item.id)
        return cellContent(for: item)

            .modifier(ShelfCardGeometryReporter(itemID: item.id))
            // The insertion marker on the leading edge of the targeted card.
            .overlay(alignment: .leading) {
                if dropTargetState.insertionIndex != nil, dropTargetState.insertionIndex == index {
                    insertionIndicator
                        .padding(.leading, -(Self.gridSpacing / 2 + 3))
                }
            }
            // After the last card when inserting at the end.
            .overlay(alignment: .trailing) {
                if dropTargetState.insertionIndex == store.items.count, index == store.items.count - 1 {
                    insertionIndicator
                        .padding(.trailing, -(Self.gridSpacing / 2 + 3))
                }
            }
    }

    @ViewBuilder
    private func cellContent(for item: ShelfItem) -> some View {
        if item.kind == .stack {
            ShelfStackView(
                item: item,
                isSelected: store.selection.contains(item.id),
                isKeyboardFocused: interaction.focusedItemID == item.id,
                isExpanded: interaction.expandedStackID == item.id,
                onSelect: { additive in select(item.id, additive: additive) },
                onToggleExpanded: { toggleStackExpansion(item.id) },
                onRemove: { store.removeForUser(ids: [item.id]) },
                onRecover: { toggleStackExpansion(item.id) },
                onCopy: {
                    copyToClipboard(ShelfActionSelectionResolver.contextualItems(
                        anchor: item,
                        visibleItems: store.items,
                        selectedIDs: store.selection
                    ))
                },
                onUnstack: { store.unstack(item.id) },
                transferStatus: stackTransferStatus(for: item),
                dragContentsProvider: dragContents(for:)
            )
        } else {
            ShelfItemCard(
                item: item,
                isSelected: store.selection.contains(item.id),
                isKeyboardFocused: interaction.focusedItemID == item.id,
                onSelect: { additive in select(item.id, additive: additive) },
                onRemove: { store.removeForUser(ids: [item.id]) },
                onRecover: { itemRecoveryController?.recover(item) },
                onCopy: item.availability == .available
                    ? {
                        copyToClipboard(ShelfActionSelectionResolver.contextualItems(
                            anchor: item,
                            visibleItems: store.items,
                            selectedIDs: store.selection
                        ))
                    }
                    : nil,
                onStack: store.canStackSelection(anchoredAt: item.id)
                    ? { store.stackSelection(anchoredAt: item.id) }
                    : nil,
                transferStatus: transferStore.accessibilityStatus(for: item.id),
                dragContentsProvider: dragContents(for:)
            )
        }
    }

    /// A card in the selection drags the whole selection (stacks are expanded
    /// when the payload is built); any other card drags only itself.
    private func dragContents(for anchor: ShelfItem) -> DragOutContents {
        let dragged = store.selection.contains(anchor.id) ? store.selectedItems : [anchor]
        return DragOutContents(items: dragged, topLevelIDs: Set(dragged.map(\.id)))
    }

    private var insertionIndicator: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 4)
            .shadow(color: Color.accentColor.opacity(0.32), radius: 3)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var dropTargetHighlight: some View {
        if dropTargetState.isTargeted, !dropTargetState.isReordering {
            RoundedRectangle(cornerRadius: settings.appearance.cornerRadius)
                .strokeBorder(dropModeTint, lineWidth: 2)
                .background {
                    RoundedRectangle(cornerRadius: settings.appearance.cornerRadius)
                        .fill(dropModeTint.opacity(0.12))
                }
                .allowsHitTesting(false)
        }
    }

    private var dropModeTint: Color {
        dropTargetState.mode == .move ? .orange : .accentColor
    }

    /// A capsule at the bottom while hovering (notices are at the top):
    /// "Release to move the original here" for ⌘, "Release to add" otherwise.
    @ViewBuilder
    private var dropModeHint: some View {
        if dropTargetState.isTargeted {
            Text(dropTargetState.isReordering
                 ? String(localized: "Release to reorder")
                 : dropTargetState.mode == .move
                 ? String(localized: "Release to move the original here ⌘")
                 : String(localized: "Release to add a reference"))
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background { Capsule().fill(.regularMaterial) }
                .padding(.bottom, 10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private var collapseHandleSide: ShelfLayoutEngine.InnerEdgeHandleSide? {
        guard presentationStyle == .classic else { return nil }
        return ShelfLayoutEngine.innerEdgeHandleSide(for: settings.shelfPosition)
    }

    private func collapseButton(side: ShelfLayoutEngine.InnerEdgeHandleSide) -> some View {
        Button {
            shelfHideAction?()
        } label: {
            Image(systemName: side == .leading ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(ShelfIconButtonStyle())

        .padding(side == .leading ? .trailing : .leading, -8)
        .padding(.vertical, -3)
        .help(Text("Hide Shelf"))
        .accessibilityLabel(Text("Hide Shelf"))
        .accessibilityIdentifier("shelf.hide.handle")
    }

    /// On the panel's screen-edge side (opposite the inner handle): trailing
    /// for a right anchor, leading for a left one; nil for custom placement.
    /// It is where the edge tab was: the tab shows only while the shelf is
    /// hidden, so clicking the same spot again collapses the open shelf.
    private var outerCollapseStripSide: ShelfLayoutEngine.InnerEdgeHandleSide? {
        switch collapseHandleSide {
        case .leading: return .trailing
        case .trailing: return .leading
        case nil: return nil
        }
    }

    private var outerCollapseStripAlignment: Alignment {
        outerCollapseStripSide == .trailing ? .trailing : .leading
    }

    @ViewBuilder
    private var outerCollapseStrip: some View {
        if outerCollapseStripSide != nil {
            Button {
                shelfHideAction?()
            } label: {
                Color.white.opacity(0.001)
            }
            .buttonStyle(.plain)
            .frame(width: ShelfLayoutEngine.innerEdgeHandleWidth)
            .frame(maxHeight: reveal?.surfaceHeight.map { $0 + 16 } ?? .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel(Text("Hide Shelf"))
            .accessibilityIdentifier("shelf.hide.edge")
            .help(Text("Hide Shelf"))
        }
    }

    // MARK: - Stack expansion

    @ViewBuilder
    private var expandedStackOverlay: some View {
        if let stackID = interaction.expandedStackID,
           let stack = store.item(withID: stackID),
           stack.kind == .stack {
            // A translucent scrim; clicking outside closes.
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture(perform: collapseStack)
                .overlay {
                    ShelfStackExpandedView(
                        stack: stack,
                        onDismiss: collapseStack,
                        interaction: interaction,
                        // A child's ✕ removes it from the stack; when the stack dissolves this
                        // overlay closes on its own (`item(withID:)` returns nil).
                        onRemoveChild: { childID in
                            store.removeChildrenForUser(ids: [childID], fromStack: stackID)
                        },
                        onRecoverChild: { child in
                            itemRecoveryController?.recover(child)
                        },
                        onCopyChild: { child in
                            copyToClipboard(ShelfActionSelectionResolver.contextualItems(
                                anchor: child,
                                visibleItems: stack.children ?? [],
                                selectedIDs: interaction.childSelection
                            ))
                        }
                    )
                    .padding(8)
                }
                .transition(.opacity)
        }
    }

    private func toggleStackExpansion(_ id: UUID) {
        withAnimation(reduceMotion ? nil : Self.cardAnimation) {
            if interaction.expandedStackID == id {
                interaction.exitStack()
            } else if let stack = store.item(withID: id) {
                interaction.enterStack(stack)
            }
        }
    }

    private func collapseStack() {
        withAnimation(reduceMotion ? nil : Self.cardAnimation) {
            interaction.exitStack()
        }
    }

    // MARK: - Selection

    private var topLevelActionItems: [ShelfItem] {
        ShelfActionSelectionResolver.explicitItems(
            topLevelItems: store.items,
            topLevelSelection: store.selection,
            expandedStackID: nil,
            childSelection: []
        )
    }

    private var shouldShowTopLevelQuickActions: Bool {
        !interaction.isSelecting
            && interaction.expandedStackID == nil
            && !dropTargetState.isTargeted
            && ShelfActionCatalog.hasAnyAction(for: topLevelActionItems)
    }

    private func select(_ id: UUID, additive: Bool) {
        interaction.focusedItemID = id
        if additive || interaction.isSelecting {
            store.toggleSelection(id)
        } else {
            store.select(id)
        }
        // While Quick Look is open, the preview follows the selection.
        quickLookCoordinator?.refreshPreview(contextItem: store.item(withID: id))
    }

    private func clearSelectionAndCollapse() {
        searchFocused = false
        shelfFocusAction?()
        showsManagementActions = false
        collapseStack()
        interaction.isSelecting = false
        store.clearSelection()
    }

    private func copyToClipboard(_ items: [ShelfItem]) {
        guard let fileServices else { return }
        let result = ClipboardController.copy(items, bookmarkService: fileServices.bookmarks)
        notices.show(ClipboardController.statusMessage(for: result))
    }

    private func stackTransferStatus(for stack: ShelfItem) -> TransferItemAccessibilityStatus? {
        let statuses = (stack.children ?? []).compactMap {
            transferStore.accessibilityStatus(for: $0.id)
        }
        if statuses.contains(.deliveryFailed) { return .deliveryFailed }
        if statuses.contains(.delivering) { return .delivering }
        if statuses.contains(.receiving) { return .receiving }
        if statuses.contains(.destinationAccepted) { return .destinationAccepted }
        if statuses.contains(.delivered) { return .delivered }
        if statuses.contains(.added) { return .added }
        return nil
    }

    /// Executes only actions that remain possible after the source drag
    /// session ends. A failed export is focused instead of claiming that a
    /// retry happened; the user still performs the real drag-out gesture.
    private func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .openStorageRecovery, .locateExternalFile:
            itemRecoveryController?.perform(action)
        case .retryByDraggingOut(let itemID):
            focusRetainedItem(itemID)
        case .dragAgainFromSource, .dismiss:
            break
        }
    }

    private func focusRetainedItem(_ itemID: UUID) {
        if store.item(withID: itemID) != nil {
            interaction.exitStack()
            interaction.focusedItemID = itemID
            store.select(itemID)
            return
        }
        guard let stack = store.items.first(where: {
            $0.kind == .stack && ($0.children ?? []).contains { $0.id == itemID }
        }) else { return }
        store.select(stack.id)
        interaction.enterStack(stack)
        interaction.focusedItemID = itemID
        interaction.childSelection = [itemID]
    }

    // MARK: - Inline notice

    /// The transient import notice below the title bar (see `ShelfNoticeModel`
    /// for why it is inline rather than an alert).
    @ViewBuilder
    private var noticeBanner: some View {
        if let message = notices.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background { Capsule().fill(.regularMaterial) }
                .padding(.top, 34)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Preview fixtures

enum ShelfPreviewFixtures {
    @MainActor
    static func makeStore() -> ShelfStore {
        ShelfStore(items: sampleItems())
    }

    static func sampleItems() -> [ShelfItem] {
        let app = ShelfItem(
            kind: .file,
            path: "/System/Library/CoreServices/Finder.app",
            displayName: "Finder",
            sourceApp: SourceAppInfo(bundleID: "com.apple.finder", name: "Finder")
        )
        let folder = ShelfItem(
            kind: .folder,
            path: "/System/Library/CoreServices",
            displayName: "CoreServices"
        )
        let image = ShelfItem(
            kind: .image,
            path: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns",
            displayName: "Finder.icns",
            sourceApp: SourceAppInfo(bundleID: "com.apple.finder", name: "Finder")
        )
        let text = ShelfItem(
            kind: .text,
            displayName: "Release notes draft",
            sourceApp: SourceAppInfo(bundleID: "com.apple.TextEdit", name: "TextEdit"),
            text: "Ship S3 shelf UI: grid, cards, stacks, empty state.\nDrag-in lands in S4."
        )
        let url = ShelfItem(
            kind: .url,
            displayName: "Apple",
            sourceApp: SourceAppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            urlString: "https://www.apple.com"
        )
        var stale = ShelfItem(
            kind: .file,
            path: "/nonexistent/moved-file.png",
            displayName: "moved-file.png"
        )
        stale.isStale = true
        return [app, folder, image, text, url, sampleStack(), stale]
    }

    static func sampleStack() -> ShelfItem {
        ShelfItem(
            kind: .stack,
            displayName: "Screenshots",
            children: [
                ShelfItem(
                    kind: .image,
                    path: "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns",
                    displayName: "Finder.icns"
                ),
                ShelfItem(
                    kind: .file,
                    path: "/System/Library/CoreServices/Finder.app",
                    displayName: "Finder"
                ),
                ShelfItem(
                    kind: .url,
                    displayName: "Apple",
                    urlString: "https://www.apple.com"
                ),
            ]
        )
    }
}

// MARK: - Previews

#Preview("Shelf with items") {
    ShelfView()
        .environment(ShelfPreviewFixtures.makeStore())
        .environment(DropTargetState())
        .environment(SettingsStore())
        .environment(\.shelfFileServices, ShelfFileServices(bookmarks: BookmarkService(), tempFiles: TempFileService()))
        .environment(ShelfGridGeometry())
        .environment(ShelfNoticeModel())
        .environment(TransferStore())
        .frame(width: 320, height: 600)
}

/// Each mounted cell owns its geometry registration. Container changes may
/// dispose an old cell after a new cell with the same item ID has reported.
private struct ShelfCardGeometryReporter: ViewModifier {
    let itemID: UUID
    @Environment(ShelfGridGeometry.self) private var geometry
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            geometry.report(frame, for: itemID, owner: owner)
        }
        .onDisappear { geometry.removeFrame(for: itemID, owner: owner) }
    }
}

#Preview("Empty shelf") {
    ShelfView()
        .environment(ShelfStore())
        .environment(DropTargetState())
        .environment(SettingsStore())
        .environment(\.shelfFileServices, ShelfFileServices(bookmarks: BookmarkService(), tempFiles: TempFileService()))
        .environment(ShelfGridGeometry())
        .environment(ShelfNoticeModel())
        .environment(TransferStore())
        .frame(width: 320, height: 600)
}
