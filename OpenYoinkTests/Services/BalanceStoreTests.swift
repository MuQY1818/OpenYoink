import XCTest
@testable import OpenYoink

@MainActor
final class BalanceStoreTests: XCTestCase {
    private func suite() throws -> (UserDefaults, String) {
        let name = "BalanceStoreTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    // MARK: Parsing

    func testDeepSeekParsing() throws {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.50"}]}"#
        let snapshot = try BalanceParsing.deepSeek(data: Data(json.utf8), now: Date())
        XCTAssertEqual(snapshot.amount, 110.50, accuracy: 0.001)
        XCTAssertEqual(snapshot.currency, "CNY")
    }

    func testDeepSeekParsingRejectsEmptyList() {
        let json = #"{"is_available":true,"balance_infos":[]}"#
        XCTAssertThrowsError(try BalanceParsing.deepSeek(data: Data(json.utf8), now: Date()))
    }

    func testOpenAICompatibleParsingConvertsCents() throws {
        let subscription = #"{"hard_limit_usd":110,"system_hard_limit_usd":110}"#
        let usage = #"{"total_usage":1234.5}"#
        let snapshot = try BalanceParsing.openAICompatible(
            subscription: Data(subscription.utf8), usage: Data(usage.utf8), now: Date())
        XCTAssertEqual(snapshot.amount, 110 - 12.345, accuracy: 0.001)
        XCTAssertEqual(snapshot.currency, "USD")
    }

    func testOpenAICompatibleParsingRejectsMissingFields() {
        XCTAssertThrowsError(try BalanceParsing.openAICompatible(
            subscription: Data("{}".utf8), usage: Data(#"{"total_usage":1}"#.utf8), now: Date()))
    }

    // MARK: Sub2API

    func testSub2APIUsageParsing() throws {
        // Real response shape from a Sub2API relay's /v1/usage.
        let json = #"{"balance":-0.0111057,"remaining":-0.0111057,"unit":"USD","planName":"钱包余额","isValid":true}"#
        let snapshot = try BalanceParsing.sub2apiUsage(data: Data(json.utf8), now: Date())
        XCTAssertEqual(snapshot.amount, -0.0111057, accuracy: 0.0000001)
        XCTAssertEqual(snapshot.currency, "USD")
    }

    func testSub2APIUsageFallsBackToBalanceField() throws {
        let json = #"{"balance":12.5,"unit":"CNY"}"#
        let snapshot = try BalanceParsing.sub2apiUsage(data: Data(json.utf8), now: Date())
        XCTAssertEqual(snapshot.amount, 12.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.currency, "CNY")
    }

    func testSub2APIUsageRejectsOneAPIShape() {
        // A one-api subscription payload must not be mistaken for a balance.
        XCTAssertThrowsError(try BalanceParsing.sub2apiUsage(
            data: Data(#"{"hard_limit_usd":110}"#.utf8), now: Date()))
    }

    // MARK: Base URL normalization

    func testBaseURLNormalization() {
        XCTAssertEqual(BalanceParsing.normalizedBaseURL("https://api.example.com")?.absoluteString,
                       "https://api.example.com")
        XCTAssertEqual(BalanceParsing.normalizedBaseURL("https://api.example.com/")?.absoluteString,
                       "https://api.example.com")
        XCTAssertEqual(BalanceParsing.normalizedBaseURL("https://api.example.com/v1/")?.absoluteString,
                       "https://api.example.com")
        XCTAssertNil(BalanceParsing.normalizedBaseURL("not a url"))
        XCTAssertNil(BalanceParsing.normalizedBaseURL("ftp://x.com"))
    }

    // MARK: Persistence

    func testEntriesPersistAcrossInstances() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BalanceStore(defaults: defaults)
        store.add(BalanceEntry(kind: .deepSeek, name: "DeepSeek"))
        store.add(BalanceEntry(kind: .openAICompatible, name: "Relay", baseURL: "https://r.example.com"))

        let reloaded = BalanceStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries[0].kind, .deepSeek)
        XCTAssertEqual(reloaded.entries[1].baseURL, "https://r.example.com")
    }

    func testRemoveDropsEntryAndCachedBalance() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BalanceStore(defaults: defaults)
        let entry = BalanceEntry(kind: .deepSeek, name: "DeepSeek")
        store.add(entry)
        XCTAssertEqual(store.entries.count, 1)

        store.remove(entry.id)
        XCTAssertEqual(store.entries.count, 0)
        XCTAssertNil(store.balances[entry.id])
        XCTAssertEqual(BalanceStore(defaults: defaults).entries.count, 0)
    }

    // MARK: Refresh with injected fetcher

    func testRefreshAllUsesInjectedFetcher() async throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = BalanceEntry(kind: .deepSeek, name: "DeepSeek")
        let store = BalanceStore(defaults: defaults, now: { Date(timeIntervalSince1970: 100) }) { _, _ in
            .success(BalanceSnapshot(amount: 42, currency: "CNY", fetchedAt: Date()))
        }
        store.add(entry)
        // add() triggers a refresh itself; wait for the task to land.
        for _ in 0..<50 where store.balances[entry.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try XCTUnwrap(store.balances[entry.id])
        XCTAssertEqual(try result.get().amount, 42, accuracy: 0.001)
    }
}
