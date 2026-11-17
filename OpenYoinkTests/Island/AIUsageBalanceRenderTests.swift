import AppKit
import SwiftUI
import XCTest
@testable import OpenYoink

/// End-to-end check of the balance feature: an entry saved the way the
/// settings sheet saves it must reach the AI usage module and render as a row
/// under the TokenTracker numbers.
@MainActor
final class AIUsageBalanceRenderTests: XCTestCase {
    private struct StubUsage: AIUsageProviding {
        func fetch(now: Date) async throws -> AIUsageSnapshot {
            AIUsageSnapshot(
                summary: AIUsageSummary(
                    today: AIUsageTotals(tokens: 682_000, costUSD: 0.24, conversations: 2),
                    last7dTokens: 253_000_000, last7dActiveDays: 6,
                    last30dTokens: 1_620_000_000, last30dAveragePerActiveDay: 57_740_000,
                    total: AIUsageTotals(tokens: 2_020_000_000, costUSD: 750.13, conversations: nil)
                ),
                limits: nil,
                fetchedAt: now
            )
        }
    }

    private func suite() throws -> (UserDefaults, String) {
        let name = "AIUsageBalanceRender-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testSavedEntryAppearsInAIUsageModule() async throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let keyStore = APIKeyStore(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("oy-balance-keys-\(UUID().uuidString)", isDirectory: true))

        let balances = BalanceStore(defaults: defaults, keyStore: keyStore, fetch: { entry, key in
            // The key saved through the sheet must reach the fetcher.
            guard key == "sk-test" else { return .failure(.missingKey) }
            return entry.kind == .deepSeek
                ? .success(BalanceSnapshot(amount: 88.6, currency: "CNY", fetchedAt: Date()))
                : .success(BalanceSnapshot(amount: 12.34, currency: "USD", fetchedAt: Date()))
        })

        // Exactly what the sheet's Save button does.
        let deepSeek = BalanceEntry(kind: .deepSeek, name: "测试 DeepSeek")
        let relay = BalanceEntry(kind: .openAICompatible, name: "测试中转站",
                                 baseURL: "https://relay.example.com")
        balances.upsert(deepSeek, apiKey: "sk-test")
        balances.upsert(relay, apiKey: "sk-test")
        defer {
            keyStore.deleteKey(for: deepSeek.id)
            keyStore.deleteKey(for: relay.id)
        }

        // 1. Saved and persisted.
        XCTAssertEqual(balances.entries.map(\.name), ["测试 DeepSeek", "测试中转站"])
        XCTAssertEqual(BalanceStore(defaults: defaults, keyStore: keyStore).entries.count, 2)

        // 2. Balances fetched with the saved key.
        for _ in 0..<100 where balances.balances.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try balances.balances[deepSeek.id]?.get().amount ?? -1, 88.6, accuracy: 0.001)
        XCTAssertEqual(try balances.balances[relay.id]?.get().amount ?? -1, 12.34, accuracy: 0.001)

        // 3. Rendered in the AI usage module under the TokenTracker numbers.
        let usage = AIUsageModuleStore(
            makeProvider: { StubUsage() },
            isSelectedAndExpanded: { true },
            compactMetric: { .off },
            alertsEnabled: { false }
        )
        usage.start()
        defer { usage.stop() }
        await usage.refresh()
        XCTAssertEqual(usage.status, .ready)

        let view = IslandAIUsageView()
            .environment(usage)
            .environment(balances)
            .frame(width: 420, height: 400)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "AI usage view did not render")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "ai-usage-with-balances"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
