import AppKit
import SwiftUI

/// Visible, non-color-only card state. Completed transfers deliberately resolve
/// to nil so the normal ready card remains quiet.
enum ShelfCardVisualStatus: Equatable {
    case receiving
    case delivering
    case destinationAccepted
    case deliveryFailed
    case managedCopy

    static func resolve(item: ShelfItem,
                        transferStatus: TransferItemAccessibilityStatus?) -> Self? {
        switch transferStatus {
        case .receiving: return .receiving
        case .delivering: return .delivering
        case .destinationAccepted: return .destinationAccepted
        case .deliveryFailed: return .deliveryFailed
        case .added, .delivered: break
        case nil: break
        }
        return item.isCut ? .managedCopy : nil
    }

    var title: String {
        switch self {
        case .receiving: String(localized: "Receiving…")
        case .delivering: String(localized: "Delivering…")
        case .destinationAccepted: String(localized: "Destination accepted")
        case .deliveryFailed: String(localized: "Not delivered")
        case .managedCopy: String(localized: "Managed copy · Original in Trash")
        }
    }

    var symbolName: String {
        switch self {
        case .receiving: "arrow.down.circle"
        case .delivering: "arrow.up.circle"
        case .destinationAccepted: "checkmark.circle"
        case .deliveryFailed: "exclamationmark.triangle.fill"
        case .managedCopy: "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .receiving, .delivering, .destinationAccepted: .secondary
        case .deliveryFailed: .red
        case .managedCopy: .orange
        }
    }
}

struct ShelfItemCard: View {
    let item: ShelfItem
    /// Accent border and tinted fill.
    let isSelected: Bool
    /// Keyboard focus is independent from multi-selection and gets its own ring.
    let isKeyboardFocused: Bool
    /// `additive` is true for ⌘-click (toggle), false for a plain click.
    let onSelect: (_ additive: Bool) -> Void
    /// Drives both the context menu item and the hover ✕ button; nil shows
    /// neither.
    var onRemove: (() -> Void)?
    /// safe recovery action selected by the parent (external reconnect,
    /// managed storage, or review a stack's unavailable children).
    var onRecover: (() -> Void)?
    /// One-shot copy action, exposed in the context menu and accessibility rotor.
    var onCopy: (() -> Void)?
    var onStack: (() -> Void)?
    var onUnstack: (() -> Void)?
    /// Runtime-only import/export state appended to the VoiceOver label.
    var transferStatus: TransferItemAccessibilityStatus?
    /// The item whose thumbnail is shown; a stack passes its first file child.
    var thumbnailItem: ShelfItem?
    /// What a drag of this card carries (whole selection, stack contents);
    /// nil drags just this card.
    var dragContentsProvider: ((ShelfItem) -> DragOutContents)?

    /// Already a SwiftUI `Image`, which is Sendable.
    @State private var thumbnail: Image?
    /// Resolved from `sourceApp.bundleID` through Launch Services.
    @State private var sourceAppIcon: NSImage?
    /// Fades the ✕ remove button in and out.
    @State private var isHovering = false
    /// Thumbnails resolve bookmarks for file access (see `ThumbnailLoader`).
    @Environment(\.shelfFileServices) private var fileServices
    /// nil (previews, tests) disables dragging; clicks still work.
    @Environment(\.dragOutController) private var dragOutController
    /// nil (previews, tests) disables Quick Look.
    @Environment(\.quickLookCoordinator) private var quickLookCoordinator
    /// Opening or revealing a text item writes a temporary .txt (see `ItemActions`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.shelfPresentationStyle) private var presentationStyle
    @Environment(\.shelfSelectionMode) private var selectionMode
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var cardCornerRadius: CGFloat {
        presentationStyle == .classic ? settings.appearance.cardCornerRadius : Self.cornerRadius
    }

    static let cornerRadius: CGFloat = 12
    /// Width follows the grid column (~88 pt).
    static let thumbnailHeight: CGFloat = 52

    init(item: ShelfItem,
         isSelected: Bool,
         isKeyboardFocused: Bool = false,
         onSelect: @escaping (_ additive: Bool) -> Void,
         onRemove: (() -> Void)? = nil,
         onRecover: (() -> Void)? = nil,
         onCopy: (() -> Void)? = nil,
         onStack: (() -> Void)? = nil,
         onUnstack: (() -> Void)? = nil,
         transferStatus: TransferItemAccessibilityStatus? = nil,
         thumbnailItem: ShelfItem? = nil,
         dragContentsProvider: ((ShelfItem) -> DragOutContents)? = nil) {
        self.item = item
        self.isSelected = isSelected
        self.isKeyboardFocused = isKeyboardFocused
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onRecover = onRecover
        self.onCopy = onCopy
        self.onStack = onStack
        self.onUnstack = onUnstack
        self.transferStatus = transferStatus
        self.thumbnailItem = thumbnailItem
        self.dragContentsProvider = dragContentsProvider
    }

    var body: some View {
        VStack(spacing: 5) {
            if item.availability == .available {
                thumbnailArea
            } else {
                availabilityArea
            }
            nameRow
            if let status = ShelfCardVisualStatus.resolve(item: item,
                                                          transferStatus: transferStatus) {
                statusRow(status)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .foregroundStyle(presentationStyle == .island
                         ? Color.white.opacity(0.90)
                         : Color.primary)
        .background { surface }
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
        .overlay { availabilityBorder }
        .overlay { keyboardFocusRing }
        .overlay(alignment: selectionMode ? .topTrailing : .topLeading) { selectionBadge }

        .overlay {
            if item.availability == .available {
                CardDragSourceBridge(
                    itemID: item.id,
                    onClick: { additive in onSelect(selectionMode || additive) },
                    onDoubleClick: {
                        guard !selectionMode else { return }
                        quickLookCoordinator?.toggle(contextItem: item)
                    },
                    onDragBegin: { sourceView, event in
                        guard let dragOutController else { return }
                        let contents = dragContentsProvider?(item)
                            ?? DragOutContents(items: [item], topLevelIDs: [item.id])
                        dragOutController.beginDrag(contents: contents,
                                                    originatingItemID: item.id,
                                                    from: sourceView,
                                                    event: event)
                    }
                )
            }
        }

        .overlay(alignment: .topTrailing) { removeButton }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovering)
        .contextMenu { contextMenu }

        .accessibilityElement(children: item.availability == .available ? .ignore : .contain)
        .accessibilityIdentifier("shelf.item.\(item.id.uuidString)")
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint(Text(cardAccessibilityHint))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect(selectionMode) }
        .accessibilityActions {
            ForEach(cardActions.filter(\.isEnabled)) { action in
                Button(action.title, action: action.perform)
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            guard item.availability != .available else { return }
            onSelect(selectionMode || NSEvent.modifierFlags.contains(.command))
        })
        .task(id: item) { await loadAssets() }
    }

    @ViewBuilder
    private var removeButton: some View {
        if !selectionMode, let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(presentationStyle == .island
                                     ? Color.white.opacity(0.72)
                                     : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background {
                        if presentationStyle == .island {
                            Circle().fill(Color.black.opacity(0.76))
                        } else {
                            Circle().fill(.regularMaterial)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(presentationStyle == .island
                                          ? Color.white.opacity(0.14)
                                          : Color.primary.opacity(0.12),
                                          lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .padding(4)
            .opacity(isHovering || isKeyboardFocused ? 1 : 0)
            .allowsHitTesting(isHovering || isKeyboardFocused)
            .help("Remove from Shelf")
            .accessibilityLabel(Text("Remove from Shelf"))
            .accessibilityIdentifier("shelf.item.\(item.id.uuidString).remove")
        }
    }

    /// e.g. "Report.pdf, File" or "Screenshots, Stack, 3 items"; cut items add
    /// that dragging them out moves the original.
    private var cardAccessibilityLabel: Text {
        var label = "\(item.displayName), \(Self.localizedKindName(for: item.kind))"
        if item.kind == .stack, let count = item.children?.count {
            label += ", " + String(localized: "\(count) items")
        }
        if item.isCut {
            label += ", " + String(localized: "Managed copy; original file moved to Trash")
        }
        label += isSelected
            ? ", " + String(localized: "Selected")
            : ", " + String(localized: "Not selected")
        if isKeyboardFocused {
            label += ", " + String(localized: "Keyboard focus")
        }
        switch item.availability {
        case .available:
            label += ", " + String(localized: "Available")
        case .externalFileOffline:
            label += ", " + String(localized: item.kind == .stack
                ? "Contains unavailable items"
                : "Original file unavailable")
        case .managedCopyMissing:
            label += ", " + String(localized: item.kind == .stack
                ? "Contains unavailable items"
                : "Managed copy missing")
        }
        if let transferStatus {
            label += ", " + transferStatus.localizedDescription
        }
        return Text(label)
    }

    private var cardAccessibilityHint: String {
        if selectionMode {
            return String(localized: "Click to select or deselect.")
        }
        if item.availability != .available {
            return availabilityActionHint
        }
        if item.kind == .stack {
            return String(localized: "Press Return to review the stack.")
        }
        return String(localized: "Press Space for Quick Look or Return to open.")
    }

    /// Localized kind name for accessibility labels.
    static func localizedKindName(for kind: ItemKind) -> String {
        switch kind {
        case .file: String(localized: "File")
        case .folder: String(localized: "Folder")
        case .text: String(localized: "Text")
        case .image: String(localized: "Image")
        case .url: String(localized: "Link")
        case .stack: String(localized: "Stack")
        }
    }

    // MARK: - Thumbnail area

    @ViewBuilder
    private var thumbnailArea: some View {
        ZStack {
            switch item.kind {
            case .text:
                textSnippetPreview
            case .url:
                urlPlaceholder
            case .file, .folder, .image, .stack:
                if let thumbnail {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    kindPlaceholder
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.thumbnailHeight)
    }

    /// A text snippet preview.
    private var textSnippetPreview: some View {
        Text(item.text ?? "")
            .font(.caption2)
            .foregroundStyle(presentationStyle == .island
                             ? Color.white.opacity(0.66)
                             : Color.secondary)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(presentationStyle == .island
                          ? Color.white.opacity(0.055)
                          : Color(nsColor: .textBackgroundColor))
            }
    }

    /// A link symbol plus the domain.
    private var urlPlaceholder: some View {
        VStack(spacing: 3) {
            Image(systemName: "link")
                .font(.title3)
            if let host = item.urlString.flatMap({ URL(string: $0)?.host() }) {
                Text(host)
                    .font(.caption2)
                    .foregroundStyle(presentationStyle == .island
                                     ? Color.white.opacity(0.46)
                                     : Color.secondary.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(presentationStyle == .island
                         ? Color.white.opacity(0.62)
                         : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown until the thumbnail has loaded.
    private var kindPlaceholder: some View {
        Image(systemName: placeholderSymbolName)
            .font(.system(size: 26))
            .foregroundStyle(presentationStyle == .island
                             ? Color.white.opacity(0.38)
                             : Color.secondary.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderSymbolName: String {
        switch item.kind {
        case .file: "doc"
        case .folder: "folder"
        case .image: "photo"
        case .text: "doc.text"
        case .url: "link"
        case .stack: "square.stack.3d.up"
        }
    }

    // MARK: - Availability

    /// Fixed-height status content replaces the thumbnail for unavailable
    /// items, keeping the grid geometry stable while exposing a real button.
    private var availabilityArea: some View {
        VStack(spacing: 2) {
            Label(availabilityStatusText, systemImage: availabilitySymbolName)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let onRecover {
                Button(availabilityActionTitle, action: onRecover)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .frame(minHeight: 24)
                    .accessibilityIdentifier("shelf.item.\(item.id.uuidString).recover")
                    .accessibilityHint(Text(availabilityActionHint))
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .frame(minHeight: Self.thumbnailHeight)
    }

    private var availabilityStatusText: String {
        if item.kind == .stack { return String(localized: "Items unavailable") }
        switch item.availability {
        case .available: return String(localized: "Available")
        case .externalFileOffline: return String(localized: "Original missing")
        case .managedCopyMissing: return String(localized: "Managed copy missing")
        }
    }

    private var availabilityActionTitle: String {
        if item.kind == .stack { return String(localized: "Review…") }
        switch item.availability {
        case .available: return ""
        case .externalFileOffline: return String(localized: "Locate…")
        case .managedCopyMissing: return String(localized: "Recovery…")
        }
    }

    private var availabilityActionHint: String {
        if item.kind == .stack {
            return String(localized: "Expand the stack to review unavailable items.")
        }
        switch item.availability {
        case .available: return ""
        case .externalFileOffline:
            return String(localized: "Locate the original file to reconnect it.")
        case .managedCopyMissing:
            return String(localized: "Open Storage settings to review recovery data.")
        }
    }

    private var availabilitySymbolName: String {
        switch item.availability {
        case .available: "checkmark.circle"
        case .externalFileOffline: "questionmark.folder"
        case .managedCopyMissing: "externaldrive.badge.exclamationmark"
        }
    }

    // MARK: - Name row

    /// Source-app icon plus up to two lines of name. Text follows the system
    /// size; the card grows instead of shrinking it.
    private var nameRow: some View {
        HStack(alignment: .top, spacing: 3) {
            if let sourceAppIcon {
                Image(nsImage: sourceAppIcon)
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(item.displayName)
                .font(.caption)
                .foregroundStyle(presentationStyle == .island
                                 ? Color.white.opacity(0.90)
                                 : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// One concise semantic state line. Active transfer/failure takes
    /// precedence over the persistent managed-copy label; completed transfers
    /// return to the quiet ready state.
    private func statusRow(_ status: ShelfCardVisualStatus) -> some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .accessibilityIdentifier("shelf.item.\(item.id.uuidString).status")
    }

    // MARK: - Surfaces & badges

    private var surface: some View {
        RoundedRectangle(cornerRadius: cardCornerRadius)
            .fill(cardFill)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: cardCornerRadius)
                        .fill(Color.accentColor.opacity(presentationStyle == .island ? 0.14 : 0.18))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .strokeBorder(cardBorder,
                                  lineWidth: isSelected ? 2 : 0.5)
            }
    }

    private var cardFill: Color {
        return presentationStyle == .island
            ? Color.white.opacity(0.06)
            : Color(nsColor: .controlBackgroundColor)
                .opacity(reduceTransparency ? 1 : settings.appearance.cardOpacity)
    }

    private var cardBorder: Color {
        if isSelected { return Color.accentColor.opacity(0.95) }
        return presentationStyle == .island
            ? Color.white.opacity(0.11)
            : Color.primary.opacity(0.08)
    }

    /// Unavailable state uses a dashed shape in addition to icon/text, so the
    /// distinction remains visible with “Differentiate Without Color.
    @ViewBuilder
    private var availabilityBorder: some View {
        if item.availability != .available {
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .strokeBorder(
                    Color.primary.opacity(0.48),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var keyboardFocusRing: some View {
        if isKeyboardFocused {
            RoundedRectangle(cornerRadius: cardCornerRadius - 2)
                .strokeBorder(selectionMode ? Color.primary.opacity(0.5) : Color(nsColor: .keyboardFocusIndicatorColor),
                              style: StrokeStyle(lineWidth: selectionMode ? 1 : (colorSchemeContrast == .increased ? 4 : 3),
                                                 dash: selectionMode ? [3, 3] : []))
                .padding(2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if selectionMode {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.55), lineWidth: 1)
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                .padding(5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if isSelected && differentiateWithoutColor {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .symbolRenderingMode(.hierarchical)
                .padding(5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private struct CardAction: Identifiable {
        let id: String
        let title: String
        var isEnabled = true
        var role: ButtonRole?
        var isVisibleInMenu = true
        let perform: () -> Void
    }

    private var cardActions: [CardAction] {
        var actions: [CardAction] = []
        if item.availability == .available {
            actions.append(CardAction(id: "preview", title: String(localized: "Quick Look"),
                                      isEnabled: quickLookCoordinator != nil && ItemActions.canQuickLook(item)) {
                quickLookCoordinator?.toggle(contextItem: item)
            })
            actions.append(CardAction(id: "open", title: String(localized: "Open"),
                                      isEnabled: ItemActions.canOpen(item)) {
                guard let fileServices else { return }
                ItemActions.open(item, bookmarkService: fileServices.bookmarks, tempFileService: fileServices.tempFiles)
            })
            actions.append(CardAction(id: "reveal", title: String(localized: "Show in Finder"),
                                      isEnabled: ItemActions.canRevealInFinder(item)) {
                guard let fileServices else { return }
                ItemActions.revealInFinder(item, bookmarkService: fileServices.bookmarks, tempFileService: fileServices.tempFiles)
            })
        }
        if let onRecover {
            actions.append(CardAction(id: "recover", title: availabilityActionTitle,
                                      isVisibleInMenu: item.availability != .available, perform: onRecover))
        }
        if let onCopy {
            actions.append(CardAction(id: "copy", title: String(localized: "Copy"), perform: onCopy))
        }
        if let onStack {
            actions.append(CardAction(id: "stack", title: String(localized: "Stack Selected Items"), perform: onStack))
        }
        if let onUnstack {
            actions.append(CardAction(id: "unstack", title: String(localized: "Unstack"), perform: onUnstack))
        }
        if let onRemove {
            actions.append(CardAction(id: "remove", title: String(localized: "Remove from Shelf"),
                                      role: .destructive, perform: onRemove))
        }
        return actions
    }

    @ViewBuilder
    private var contextMenu: some View {
        if item.availability != .available {
            Label(availabilityStatusText, systemImage: availabilitySymbolName)
        }
        ForEach(cardActions.filter(\.isVisibleInMenu)) { action in
            if action.role == .destructive { Divider() }
            Button(action.title, role: action.role, action: action.perform)
                .disabled(!action.isEnabled)
        }
    }

    // MARK: - Asset loading

    /// Thumbnail (generated in the background) and source-app icon.
    private func loadAssets() async {
        guard let fileServices else { return }
        thumbnail = await ThumbnailLoader.thumbnail(
            for: thumbnailItem ?? item,
            pointSize: CGSize(width: 88, height: Self.thumbnailHeight),
            bookmarkService: fileServices.bookmarks
        )
        sourceAppIcon = ThumbnailLoader.sourceAppIcon(bundleID: item.sourceApp?.bundleID)
    }
}

// MARK: - Previews

#Preview("Item cards") {
    let items = ShelfPreviewFixtures.sampleItems().filter { $0.kind != .stack }
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 12) {
        ForEach(items) { item in
            ShelfItemCard(item: item,
                          isSelected: item.kind == .image,
                          onSelect: { _ in },
                          onRemove: {})
        }
    }
    .padding()
    .frame(width: 320)
    .environment(SettingsStore())
    .environment(\.shelfFileServices, ShelfFileServices(bookmarks: BookmarkService(), tempFiles: TempFileService()))
}
