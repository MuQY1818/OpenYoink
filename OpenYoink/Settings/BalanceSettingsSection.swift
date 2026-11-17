import SwiftUI

/// Settings section for balance query sources: add, edit and remove entries.
/// API keys are stored in a 0600 file inside the app's sandbox and are never
/// displayed back.
struct BalanceSettingsSection: View {
    @Environment(BalanceStore.self) private var balanceStore
    @State private var editingEntry: BalanceEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if balanceStore.entries.isEmpty {
                Text("No balance sources yet. Add DeepSeek or an OpenAI-compatible relay to see remaining balance in the AI usage module.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(balanceStore.entries) { entry in
                    entryRow(entry)
                }
            }
            Button("Add Balance Source") {
                editingEntry = BalanceEntry(kind: .openAICompatible, name: "")
            }
        }
        .sheet(item: $editingEntry) { entry in
            BalanceEntryEditor(original: entry,
                               hadKey: balanceStore.hasKey(for: entry.id))
        }
    }

    private func entryRow(_ entry: BalanceEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.isEmpty ? "(unnamed)" : entry.name)
                    .font(.body.weight(.medium))
                Text(entry.kind == .deepSeek
                     ? String(localized: "DeepSeek")
                     : String(localized: "OpenAI-compatible relay · \(entry.baseURL)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Edit") {
                editingEntry = entry
            }
            Button("Remove", role: .destructive) {
                balanceStore.remove(entry.id)
            }
        }
    }
}

/// Form shown in the sheet. Copies the entry into local state so edits only
/// commit on Save.
private struct BalanceEntryEditor: View {
    @Environment(BalanceStore.self) private var balanceStore
    @Environment(\.dismiss) private var dismiss

    let original: BalanceEntry
    let hadKey: Bool

    @State private var kind: BalanceKind
    @State private var name: String
    @State private var baseURL: String
    @State private var apiKey: String

    init(original: BalanceEntry, hadKey: Bool) {
        self.original = original
        self.hadKey = hadKey
        _kind = State(initialValue: original.kind)
        _name = State(initialValue: original.name)
        _baseURL = State(initialValue: original.baseURL)
        _apiKey = State(initialValue: "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Falls back to a sensible name so the entry is always identifiable.
    private var defaultName: String {
        switch kind {
        case .deepSeek: return "DeepSeek"
        case .openAICompatible:
            return BalanceParsing.normalizedBaseURL(baseURL)?.host() ?? "Relay"
        }
    }

    var body: some View {
        Form {
            Picker("Type", selection: $kind) {
                Text("DeepSeek").tag(BalanceKind.deepSeek)
                Text("OpenAI-compatible relay").tag(BalanceKind.openAICompatible)
            }
            TextField("Name", text: $name)
            TextField("Base URL", text: $baseURL,
                      prompt: Text(kind == .deepSeek
                                   ? "https://api.deepseek.com"
                                   : "https://api.example.com"))
                .disabled(kind == .deepSeek)
            SecureField("API Key", text: $apiKey,
                        prompt: Text(hadKey && apiKey.isEmpty
                                     ? String(localized: "Saved — leave empty to keep")
                                     : String(localized: "sk-…")))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        var entry = original
        entry.kind = kind
        entry.name = trimmedName.isEmpty ? defaultName : trimmedName
        entry.baseURL = kind == .openAICompatible ? baseURL.trimmingCharacters(in: .whitespaces) : ""
        balanceStore.upsert(entry, apiKey: apiKey)
        dismiss()
    }
}
