import SwiftUI

struct IslandShelfModuleView: View {
    @Environment(ShelfStore.self) private var shelfStore

    var body: some View {
        VStack(spacing: 8) {
            IslandModuleHeader(
                title: "Shelf",
                subtitle: String(localized: "\(shelfStore.items.count) items"),
                systemImage: "tray.full"
            )
            ShelfView(presentationStyle: .island)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct IslandTransfersView: View {
    @Environment(TransferStore.self) private var transferStore
    @State private var showingDownloads = false
    var onPerformRecovery: ((RecoveryAction) -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Picker("Transfers View", selection: $showingDownloads) {
                Text("Transfers").tag(false)
                Text("Recent Downloads").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel(Text("Transfers View"))

            if showingDownloads {
                RecentDownloadsView()
            } else if transferStore.hasVisibleActivity {
                ShelfActivityStrip(onPerformRecovery: onPerformRecovery)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                IslandEmptyState(
                    title: "All caught up",
                    message: "New imports and deliveries appear here.",
                    systemImage: "checkmark.circle"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
