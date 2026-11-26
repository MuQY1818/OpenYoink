import SwiftUI

struct ShelfStackView: View {
    @Environment(\.shelfSelectionMode) private var selectionMode
    let item: ShelfItem
    let isSelected: Bool
    var isKeyboardFocused: Bool = false
    /// While open the card stays highlighted ("click again to close").
    let isExpanded: Bool
    /// `additive` is true for ⌘-click (toggle), false for a plain click.
    let onSelect: (_ additive: Bool) -> Void
    let onToggleExpanded: () -> Void
    var onRemove: (() -> Void)?
    var onRecover: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onUnstack: (() -> Void)? = nil
    var transferStatus: TransferItemAccessibilityStatus? = nil
    /// What a drag carries (ShelfView decides for selections and stacks).
    var dragContentsProvider: ((ShelfItem) -> DragOutContents)?

    var body: some View {
        ShelfItemCard(
            item: item,
            isSelected: isSelected || (!selectionMode && isExpanded),
            isKeyboardFocused: isKeyboardFocused,
            onSelect: { additive in
                if selectionMode || additive {
                    onSelect(true)
                } else {
                    onSelect(false)
                    onToggleExpanded()
                }
            },
            onRemove: onRemove,
            onRecover: onRecover,
            onCopy: onCopy,
            onUnstack: onUnstack,
            transferStatus: transferStatus,
            thumbnailItem: item.children?.first(where: { $0.fileURL != nil }),
            dragContentsProvider: dragContentsProvider
        )
        .overlay(alignment: selectionMode ? .topLeading : .topTrailing) { countBadge }
    }

    /// The accent count capsule, top right.
    private var countBadge: some View {
        Text("\(item.children?.count ?? 0)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background { Capsule().fill(Color.accentColor) }
            .padding(5)
            .allowsHitTesting(false)
    }
}

struct ShelfStackExpandedView: View {
    @Environment(TransferStore.self) private var transferStore
    @Environment(DropTargetState.self) private var dropTargetState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shelfSelectionMode) private var selectionMode
    let stack: ShelfItem
    let onDismiss: () -> Void
    let interaction: ShelfInteractionState
    /// nil renders no ✕ on children.
    var onRemoveChild: ((UUID) -> Void)?
    /// child-specific availability recovery.
    var onRecoverChild: ((ShelfItem) -> Void)? = nil
    var onCopyChild: ((ShelfItem) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 12)]

    var body: some View {
        VStack(spacing: 8) {
            header
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(stack.children ?? []) { child in
                        ShelfItemCard(
                            item: child,
                            isSelected: interaction.childSelection.contains(child.id),
                            isKeyboardFocused: interaction.focusedItemID == child.id,
                            onSelect: { additive in
                                interaction.focusedItemID = child.id
                                if selectionMode || additive {
                                    interaction.childSelection.formSymmetricDifference([child.id])
                                } else {
                                    interaction.childSelection = [child.id]
                                }
                            },
                            onRemove: onRemoveChild.map { remove in
                                { remove(child.id) }
                            },
                            onRecover: onRecoverChild.map { recover in
                                { recover(child) }
                            },
                            onCopy: child.availability == .available
                                ? onCopyChild.map { copy in { copy(child) } }
                                : nil,
                            transferStatus: transferStore.accessibilityStatus(for: child.id),
                            dragContentsProvider: dragContents(for:)
                        )
                    }
                }
                .padding(2)
                .animation(reduceMotion ? nil : ShelfView.cardAnimation,
                           value: interaction.childSelection)
                .animation(reduceMotion ? nil : ShelfView.cardAnimation,
                           value: stack.children)
            }
            .frame(maxHeight: 320)
            if shouldShowQuickActions {
                ShelfQuickActionBar(items: selectedActionItems)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
        }
    }

    /// The child selection when it includes this child, else just the child;
    /// no top-level IDs (children aren't removed from the stack).
    private func dragContents(for anchor: ShelfItem) -> DragOutContents {
        let children = stack.children ?? []
        let dragged = interaction.childSelection.contains(anchor.id) && interaction.childSelection.count > 1
            ? children.filter { interaction.childSelection.contains($0.id) }
            : [anchor]
        return DragOutContents(items: dragged, topLevelIDs: [])
    }

    private var selectedActionItems: [ShelfItem] {
        (stack.children ?? []).filter { interaction.childSelection.contains($0.id) }
    }

    private var shouldShowQuickActions: Bool {
        !dropTargetState.isTargeted
            && ShelfActionCatalog.hasAnyAction(for: selectedActionItems)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(stack.displayName)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(stack.children?.count ?? 0) items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Collapse stack")
            .accessibilityLabel(Text("Collapse stack"))
            .accessibilityIdentifier("shelf.stack.\(stack.id.uuidString).collapse")
        }
    }
}

// MARK: - Previews

#Preview("Stack card") {
    let stack = ShelfPreviewFixtures.sampleStack()
    ShelfStackView(item: stack,
                   isSelected: false,
                   isExpanded: false,
                   onSelect: { _ in },
                   onToggleExpanded: {},
                   onRemove: {})
        .frame(width: 100)
        .padding()
        .environment(SettingsStore())
}

#Preview("Stack expanded") {
    ShelfStackExpandedView(stack: ShelfPreviewFixtures.sampleStack(),
                           onDismiss: {},
                           interaction: ShelfInteractionState())
        .frame(width: 288)
        .padding()
        .environment(SettingsStore())
}
