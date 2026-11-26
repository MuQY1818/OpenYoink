import SwiftUI

struct ShelfEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text("Drop files here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // The two drop modes (plain drop = reference; ⌘-drop = move the original in).
                Text("Hold ⌘ while dropping to move the original here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("⌘⇧Space to toggle the shelf")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shelf.emptyState")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(0.13),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 5])
                )
        }
        .padding(8)
    }
}

// MARK: - Previews

#Preview("Empty state") {
    ShelfEmptyState()
        .frame(width: 280, height: 400)
}
