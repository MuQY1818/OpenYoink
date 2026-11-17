import SwiftUI

/// Island notes module: one editable scratch note with a one-tap clear button.
struct IslandNotesView: View {
    @Environment(NotesModuleStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 8) {
            IslandModuleHeader(
                title: "Notes",
                subtitle: String(localized: "Saved automatically on this Mac"),
                systemImage: NotesModuleStore.moduleDescriptor.systemImage
            )
            .overlay(alignment: .trailing) {
                if !store.text.isEmpty {
                    clearButton
                }
            }

            TextEditor(text: $store.text)
                .font(.system(size: 12))
                .foregroundStyle(IslandVisualStyle.primaryText)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(IslandVisualStyle.cardFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
                        }
                }
                .accessibilityLabel(Text("Note"))
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { store.flush() }
    }

    private var clearButton: some View {
        Button {
            store.clear()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                Text("Clear")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.red.opacity(0.9))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.red.opacity(0.12)))
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        .help(Text("Clear the note"))
        .accessibilityLabel(Text("Clear the note"))
    }
}
