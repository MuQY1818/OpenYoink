import Foundation
import NaturalLanguage
import Observation
@preconcurrency import Translation

extension IslandModuleID {
    static let translate = Self(rawValue: "translate")
}

/// Splits pasted text into lines so each subtitle line is translated on its
/// own and the result keeps the same line count and blank-line positions.
/// Pure value type: the alignment rules are unit-tested without Translation.
struct TranslateLineBatch: Equatable, Sendable {
    /// Every original line, in order. Blank (whitespace-only) lines are kept
    /// verbatim and are never sent to the translation engine.
    let lines: [String]

    init(_ text: String) {
        lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Indices of the lines that carry text to translate.
    var translatableIndices: [Int] {
        lines.indices.filter { !Self.isBlank(lines[$0]) }
    }

    var isEmpty: Bool { translatableIndices.isEmpty }

    /// Rebuilds the text, replacing each translatable line by its translation.
    /// A line without a translation (missing key) falls back to the original.
    func assemble(_ translations: [Int: String]) -> String {
        lines.indices.map { index in
            Self.isBlank(lines[index]) ? lines[index] : (translations[index] ?? lines[index])
        }
        .joined(separator: "\n")
    }

    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Target languages offered by the module. Identifiers are BCP-47 codes
/// understood by `Locale.Language(identifier:)`.
enum TranslateTargetLanguage {
    static let defaultIdentifier = "zh-Hans"
    static let identifiers = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "es", "fr", "de",
        "ru", "pt", "it", "vi", "th", "id", "ar",
    ]

    static func displayName(for identifier: String) -> String {
        // Follow the app's UI language rather than the system region.
        let ui = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return ui.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Runs one batch against a session. Kept free of actor isolation so the
/// non-Sendable `TranslationSession` never crosses an isolation boundary.
enum TranslateEngine {
    /// Pure: one request per non-blank line, keyed by line index.
    nonisolated static func requests(for batch: TranslateLineBatch) -> [TranslationSession.Request] {
        batch.translatableIndices.map {
            TranslationSession.Request(sourceText: batch.lines[$0], clientIdentifier: String($0))
        }
    }

    /// Pure: folds translated responses back into whole text.
    nonisolated static func assemble(_ batch: TranslateLineBatch,
                                     responses: [TranslationSession.Response]) -> String {
        var translations: [Int: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id) {
                translations[index] = response.targetText
            }
        }
        return batch.assemble(translations)
    }
}

/// Island translate module: paste text on top, read the translation below.
/// Text lives in memory only; nothing is written to disk or kept as history.
@MainActor
@Observable
final class TranslateModuleStore {
    static let moduleDescriptor = IslandModuleDescriptor(
        id: .translate,
        title: String(localized: "Translate"),
        systemImage: "translate",
        order: 9,
        isCore: false
    )

    enum Status: Equatable {
        case idle
        case translating
        case failed(String)
    }

    var sourceText = ""
    var translatedText = ""
    private(set) var status: Status = .idle

    /// Bound to `.translationTask`. Replacing or invalidating it asks SwiftUI
    /// to hand the view a fresh session for the current text.
    var configuration: TranslationSession.Configuration?

    var targetLanguageIdentifier: String {
        didSet {
            defaults.set(targetLanguageIdentifier, forKey: Self.targetLanguageKey)
            configuration = nil
            requestTranslation()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingText: String?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    static let targetLanguageKey = "OpenYoink.translateTargetLanguage"
    static let debounce: Duration = .milliseconds(600)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.targetLanguageKey)
        targetLanguageIdentifier = stored.flatMap {
            TranslateTargetLanguage.identifiers.contains($0) ? $0 : nil
        } ?? TranslateTargetLanguage.defaultIdentifier
    }

    /// Called on every edit of the source text; translates after a short pause
    /// so typing or pasting several times does not start a request per key.
    func sourceTextDidChange() {
        debounceTask?.cancel()
        if TranslateLineBatch(sourceText).isEmpty {
            translatedText = ""
            status = .idle
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.requestTranslation()
        }
    }

    func requestTranslation() {
        guard !TranslateLineBatch(sourceText).isEmpty else { return }
        let target = Locale.Language(identifier: targetLanguageIdentifier)
        // Detect the source locally first: passing nil lets the translation
        // engine fall back to its own detector, which interrupts the user with
        // a "choose the language" sheet whenever it isn't confident.
        guard let detected = Self.detectLanguage(sourceText) else {
            translatedText = ""
            status = .failed(String(localized: "Couldn't detect the source language. Try pasting a few more words."))
            return
        }
        if detected.languageCode == target.languageCode {
            translatedText = ""
            status = .failed(String(localized: "The text is already in the target language."))
            return
        }
        pendingText = sourceText
        status = .translating
        if configuration == nil {
            configuration = .init(source: detected, target: target)
        } else {
            configuration?.source = detected
            configuration?.target = target
            configuration?.invalidate()
        }
    }

    /// Local language detection (BCP-47). Nil when the text has no language.
    nonisolated static func detectLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Text the next session should translate, consumed once.
    func takePendingText() -> String? {
        defer { pendingText = nil }
        return pendingText
    }

    func finish(source: String, translated: String) {
        // A newer edit is already queued; its own session will report.
        guard source == sourceText else { return }
        translatedText = translated
        status = .idle
    }

    func fail(source: String, message: String) {
        guard source == sourceText else { return }
        status = .failed(message)
    }

    func clear() {
        debounceTask?.cancel()
        sourceText = ""
        translatedText = ""
        status = .idle
    }

    nonisolated static func message(for error: any Error) -> String {
        if error is CancellationError {
            return String(localized: "Translation was cancelled.")
        }
        // TranslationError is a struct matched through its `~=` overload.
        switch error {
        case TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing:
            return String(localized: "This language pair isn't supported. The text may already be in the target language.")
        case TranslationError.unableToIdentifyLanguage:
            return String(localized: "Couldn't detect the source language.")
        case TranslationError.nothingToTranslate:
            return String(localized: "Nothing to translate.")
        default:
            // `notInstalled` only exists on macOS 26+ (deployment target is 15).
            if #available(macOS 26.0, *), case TranslationError.notInstalled = error {
                return String(localized: "The language isn't downloaded yet. Download it in System Settings.")
            }
            return String(localized: "Translation failed. You may need to download the language in System Settings.")
        }
    }

    /// System Settings → General → Language & Region (translation languages).
    static let languageSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Localization-Settings.extension"
    )!
}
