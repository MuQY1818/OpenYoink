import XCTest
@testable import OpenYoink

final class TranslateLineBatchTests: XCTestCase {
    func testKeepsLineCountAndBlankLines() {
        let batch = TranslateLineBatch("Hello\n\nWorld\n  \nBye")
        XCTAssertEqual(batch.lines.count, 5)
        XCTAssertEqual(batch.translatableIndices, [0, 2, 4])
        let output = batch.assemble([0: "你好", 2: "世界", 4: "再见"])
        XCTAssertEqual(output, "你好\n\n世界\n  \n再见")
    }

    func testNormalizesWindowsAndClassicLineEndings() {
        let batch = TranslateLineBatch("a\r\nb\rc")
        XCTAssertEqual(batch.lines, ["a", "b", "c"])
    }

    func testMissingTranslationFallsBackToOriginal() {
        let batch = TranslateLineBatch("one\ntwo")
        XCTAssertEqual(batch.assemble([1: "二"]), "one\n二")
    }

    func testWhitespaceOnlyTextIsEmpty() {
        XCTAssertTrue(TranslateLineBatch("").isEmpty)
        XCTAssertTrue(TranslateLineBatch("   \n  ").isEmpty)
        XCTAssertFalse(TranslateLineBatch("\nx\n").isEmpty)
    }

    func testSubtitleBlockKeepsIndexAndTimecodeLines() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nHello there\n\n2\n00:00:03,000 --> 00:00:04,000\nGood bye"
        let batch = TranslateLineBatch(srt)
        XCTAssertEqual(batch.lines.count, 7)
        XCTAssertEqual(batch.assemble([:]), srt)
    }
}

@MainActor
final class TranslateModuleStoreTests: XCTestCase {
    private func suite() throws -> (UserDefaults, String) {
        let name = "TranslateModuleTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testDefaultsToSimplifiedChineseAndPersistsChoice() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TranslateModuleStore(defaults: defaults)
        XCTAssertEqual(store.targetLanguageIdentifier, "zh-Hans")
        store.targetLanguageIdentifier = "en"
        XCTAssertEqual(TranslateModuleStore(defaults: defaults).targetLanguageIdentifier, "en")
    }

    func testUnknownStoredLanguageFallsBackToDefault() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("xx-Bogus", forKey: TranslateModuleStore.targetLanguageKey)
        XCTAssertEqual(TranslateModuleStore(defaults: defaults).targetLanguageIdentifier, "zh-Hans")
    }

    func testRequestCreatesConfigurationAndQueuesText() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TranslateModuleStore(defaults: defaults)
        store.sourceText = "Hello"
        store.requestTranslation()
        XCTAssertEqual(store.status, .translating)
        XCTAssertEqual(store.configuration?.target?.minimalIdentifier, "zh")
        XCTAssertEqual(store.takePendingText(), "Hello")
        XCTAssertNil(store.takePendingText())
    }

    func testStaleResultIsIgnored() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TranslateModuleStore(defaults: defaults)
        store.sourceText = "new"
        store.finish(source: "old", translated: "旧")
        XCTAssertEqual(store.translatedText, "")
        store.finish(source: "new", translated: "新")
        XCTAssertEqual(store.translatedText, "新")
        XCTAssertEqual(store.status, .idle)
    }

    func testClearingSourceClearsTranslation() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TranslateModuleStore(defaults: defaults)
        store.sourceText = "x"
        store.finish(source: "x", translated: "y")
        store.sourceText = ""
        store.sourceTextDidChange()
        XCTAssertEqual(store.translatedText, "")
        XCTAssertEqual(store.status, .idle)
    }

    func testDescriptorIsRegisteredInModuleLibrary() {
        let registry = IslandModuleRegistry()
        XCTAssertTrue(registry.descriptors.contains { $0.id == .translate })
    }

    // MARK: Language detection (avoids the system "pick a language" sheet)

    func testDetectsChinese() {
        let language = TranslateModuleStore.detectLanguage("今天天气很好，我们一起去公园散步吧")
        XCTAssertEqual(language?.languageCode, "zh")
    }

    func testDetectsEnglish() {
        let language = TranslateModuleStore.detectLanguage("The quick brown fox jumps over the lazy dog")
        XCTAssertEqual(language?.languageCode, "en")
    }

    func testConfigurationUsesDetectedSource() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TranslateModuleStore(defaults: defaults)
        store.sourceText = "Hello world, this is a subtitle line."
        store.requestTranslation()
        XCTAssertEqual(store.status, .translating)
        XCTAssertEqual(store.configuration?.source?.languageCode, "en")
    }

    func testSameLanguageAsTargetSkipsTranslation() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TranslateModuleStore(defaults: defaults)
        store.targetLanguageIdentifier = "en"
        store.sourceText = "This is already English text."
        store.requestTranslation()
        guard case .failed = store.status else {
            return XCTFail("expected a failure state, got \(store.status)")
        }
        XCTAssertNil(store.configuration?.source)
    }
}
