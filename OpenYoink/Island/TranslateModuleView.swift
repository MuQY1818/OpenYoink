import AppKit
import SwiftUI
@preconcurrency import Translation

/// Island translate module. The source area is editable (paste or type);
/// the translation area is read-only but selectable, with one copy button.
struct IslandTranslateView: View {
    @Environment(TranslateModuleStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didCopy = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 8) {
            IslandModuleHeader(
                title: "Translate",
                subtitle: String(localized: "Apple Translation · on this Mac"),
                systemImage: TranslateModuleStore.moduleDescriptor.systemImage
            )
            .overlay(alignment: .trailing) { targetPicker }

            sourceArea(text: $store.sourceText)
            translationArea
            statusLine
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .translationTask(store.configuration) { session in
            // The session is not Sendable, so it never leaves this closure:
            // only plain values cross the MainActor boundary.
            let text = await MainActor.run { store.takePendingText() }
            guard let text else { return }
            let batch = TranslateLineBatch(text)
            let requests = TranslateEngine.requests(for: batch)
            do {
                let responses = requests.isEmpty
                    ? [] : try await session.translations(from: requests)
                let translated = TranslateEngine.assemble(batch, responses: responses)
                await MainActor.run { store.finish(source: text, translated: translated) }
            } catch {
                let message = TranslateModuleStore.message(for: error)
                await MainActor.run { store.fail(source: text, message: message) }
            }
        }
    }

    // MARK: Header

    private var targetPicker: some View {
        @Bindable var store = store
        return Menu {
            Picker("Translate to", selection: $store.targetLanguageIdentifier) {
                ForEach(TranslateTargetLanguage.identifiers, id: \.self) { id in
                    Text(TranslateTargetLanguage.displayName(for: id)).tag(id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: "→ \(TranslateTargetLanguage.displayName(for: store.targetLanguageIdentifier))")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(IslandVisualStyle.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(IslandVisualStyle.controlFill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Target language"))
    }

    // MARK: Text areas

    private func sourceArea(text: Binding<String>) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 12))
                .foregroundStyle(IslandVisualStyle.primaryText)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .onChange(of: text.wrappedValue) { _, _ in
                    store.sourceTextDidChange()
                }
                .accessibilityLabel(Text("Text to translate"))

            if text.wrappedValue.isEmpty {
                Text("Paste subtitles or text here")
                    .font(.system(size: 12))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fieldBackground)
        .overlay(alignment: .topTrailing) {
            if !text.wrappedValue.isEmpty {
                iconButton("xmark.circle.fill", label: "Clear") { store.clear() }
                    .padding(6)
            }
        }
    }

    private var translationArea: some View {
        ScrollView {
            Text(store.translatedText.isEmpty ? " " : store.translatedText)
                .font(.system(size: 12))
                .foregroundStyle(IslandVisualStyle.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .padding(.trailing, 22)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fieldBackground)
        .overlay {
            if store.translatedText.isEmpty, store.status == .translating {
                ProgressView().controlSize(.small)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !store.translatedText.isEmpty {
                iconButton(didCopy ? "checkmark" : "doc.on.doc",
                           label: didCopy ? "Copied" : "Copy Translation") {
                    copyTranslation()
                }
                .padding(6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Translation"))
    }

    @ViewBuilder
    private var statusLine: some View {
        if case let .failed(message) = store.status {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("Language Settings") {
                    NSWorkspace.shared.open(TranslateModuleStore.languageSettingsURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .foregroundStyle(Color.orange)
        }
    }

    // MARK: Pieces

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(IslandVisualStyle.cardFill)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
            }
    }

    private func iconButton(_ systemImage: String, label: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(IslandVisualStyle.controlFill))
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    // MARK: Actions

    private func copyTranslation() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.translatedText, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}
