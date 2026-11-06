import XCTest
@testable import OpenYoink

/// Fixtures are trimmed from real TokenTracker 1.5.10 responses.
final class AIUsageParsingTests: XCTestCase {
    private let summaryJSON = """
    {"from":"2026-11-06","to":"2026-11-06","days":1,"scope":"all",
     "totals":{"total_tokens":125161550,"billable_total_tokens":125161550,
               "total_cost_usd":"19.544926","conversation_count":218},
     "rolling":{"last_7d":{"from":"2026-10-31","to":"2026-11-06","active_days":7,
                           "totals":{"billable_total_tokens":5047855233,"conversation_count":4448}},
                "last_30d":{"from":"2026-10-08","to":"2026-11-06","active_days":30,
                            "totals":{"billable_total_tokens":12606751736},
                            "avg_per_active_day":420225058}}}
    """

    private let limitsJSON = """
    {"fetched_at":"2026-11-06T08:17:51.720Z",
     "kimi":{"configured":true,"error":"Kimi token refresh failed (HTTP 400)"},
     "claude":{"configured":true,"error":null,"plan_label":"Pro",
               "five_hour":{"utilization":23,"resets_at":"2026-11-06T12:10:00.071314+00:00"},
               "seven_day":{"utilization":41,"resets_at":"2026-11-11T17:00:00.071335+00:00"},
               "seven_day_opus":null,
               "extra_usage":{"is_enabled":false,"utilization":null}},
     "codex":{"configured":true,
              "primary_window":{"used_percent":96,"reset_at":1793880000},
              "secondary_window":{"used_percent":12,"reset_at":1794300000}},
     "cursor":{"configured":false},
     "zcode":{"configured":true,"error":null,"plan_label":null}}
    """

    func testSummaryDecodesStringCostAndRollingWindows() throws {
        let response = try TokenTrackerSummaryResponse.decode(Data(summaryJSON.utf8))
        XCTAssertEqual(response.asTotals.tokens, 125_161_550)
        XCTAssertEqual(response.asTotals.costUSD ?? 0, 19.544926, accuracy: 0.000001)
        XCTAssertEqual(response.asTotals.conversations, 218)
        XCTAssertEqual(response.rolling?.last7d?.totals?.billableTotalTokens, 5_047_855_233)
        XCTAssertEqual(response.rolling?.last7d?.activeDays, 7)
        XCTAssertEqual(response.rolling?.last30d?.avgPerActiveDay, 420_225_058)
    }

    func testSummaryToleratesMissingFields() throws {
        let response = try TokenTrackerSummaryResponse.decode(Data(#"{"totals":{"total_cost_usd":3.5}}"#.utf8))
        XCTAssertEqual(response.asTotals.tokens, 0)
        XCTAssertEqual(response.asTotals.costUSD, 3.5)
        XCTAssertNil(response.rolling)
    }

    func testLimitsFlattenProvidersInOrderAndCollectIssues() throws {
        let limits = try AIUsageLimitsParser.parse(Data(limitsJSON.utf8))
        XCTAssertEqual(limits.windows.map(\.id), [
            "claude.five_hour", "claude.seven_day",
            "codex.primary_window", "codex.secondary_window",
        ])
        XCTAssertEqual(limits.windows[0].fraction, 0.23, accuracy: 0.0001)
        XCTAssertEqual(limits.windows[0].title, "Claude · \(AIUsageLabels.fiveHour)")
        XCTAssertEqual(limits.windows[2].title, "Codex · \(AIUsageLabels.fiveHour)")
        XCTAssertEqual(limits.windows[3].title, "Codex · \(AIUsageLabels.weekly)")
        XCTAssertEqual(limits.windows[2].resetsAt, Date(timeIntervalSince1970: 1_793_880_000))
        XCTAssertNotNil(limits.windows[0].resetsAt)
        // Errors only matter for configured providers without any window.
        XCTAssertEqual(limits.issues.map(\.provider), ["kimi"])
        XCTAssertEqual(limits.tightestWindow?.id, "codex.primary_window")
    }

    func testDateParsingAcceptsMicrosecondsZuluAndEpochMilliseconds() {
        let micro = AIUsageLimitsParser.date("2026-11-06T12:10:00.071314+00:00")
        let zulu = AIUsageLimitsParser.date("2026-11-06T12:10:00Z")
        XCTAssertEqual(micro, zulu)
        XCTAssertEqual(AIUsageLimitsParser.date(1_793_880_000_000),
                       Date(timeIntervalSince1970: 1_793_880_000))
        XCTAssertNil(AIUsageLimitsParser.date("not a date"))
        XCTAssertNil(AIUsageLimitsParser.date(nil))
    }

    func testUnknownProviderGetsReadableNameAndFallbackLabel() throws {
        let json = #"{"newTool":{"configured":true,"primary_window":{"used_percent":50}}}"#
        let limits = try AIUsageLimitsParser.parse(Data(json.utf8))
        XCTAssertEqual(limits.windows.first?.title, "NewTool")
        XCTAssertEqual(limits.windows.first?.fraction, 0.5)
    }
}

final class AIUsageFormatTests: XCTestCase {
    func testTokensUseChineseUnits() {
        XCTAssertEqual(AIUsageFormat.tokens(125_161_550, chinese: true), "1.25 亿")
        XCTAssertEqual(AIUsageFormat.tokens(23_036_671_104, chinese: true), "230 亿")
        XCTAssertEqual(AIUsageFormat.tokens(56_000, chinese: true), "5.6 万")
        XCTAssertEqual(AIUsageFormat.tokens(950, chinese: true), "950")
    }

    func testTokensUseEnglishUnits() {
        XCTAssertEqual(AIUsageFormat.tokens(125_161_550, chinese: false), "125M")
        XCTAssertEqual(AIUsageFormat.tokens(5_047_855_233, chinese: false), "5.05B")
        XCTAssertEqual(AIUsageFormat.tokens(1_500, chinese: false), "1.5K")
    }

    func testCostFormats() {
        XCTAssertEqual(AIUsageFormat.cost(19.544926), "$19.54")
        XCTAssertEqual(AIUsageFormat.cost(9515.27), "$9,515")
        XCTAssertEqual(AIUsageFormat.cost(nil), "--")
        XCTAssertEqual(AIUsageFormat.compactCost(19.544926), "$19.5")
        XCTAssertEqual(AIUsageFormat.compactCost(976.9), "$977")
        XCTAssertEqual(AIUsageFormat.compactCost(2438.3), "$2.4K")
    }

    func testRefreshPolicy() {
        XCTAssertEqual(AIUsageRefreshPolicy.interval(isSelectedAndExpanded: true, showsCompactValue: true,
                                                     isConstrained: false), .seconds(30))
        XCTAssertEqual(AIUsageRefreshPolicy.interval(isSelectedAndExpanded: false, showsCompactValue: true,
                                                     isConstrained: false), .seconds(60))
        XCTAssertEqual(AIUsageRefreshPolicy.interval(isSelectedAndExpanded: false, showsCompactValue: false,
                                                     isConstrained: true), .seconds(600))
    }
}

final class AIUsageAlertTests: XCTestCase {
    private func window(_ fraction: Double, reset: TimeInterval = 1_000_000) -> AIUsageLimitWindow {
        AIUsageLimitWindow(id: "claude.five_hour", provider: "claude", providerName: "Claude",
                           windowLabel: "5h", fraction: fraction,
                           resetsAt: Date(timeIntervalSince1970: reset))
    }

    func testUsageAlreadyHighAtStartIsRecordedSilently() {
        var evaluator = AIUsageLimitAlertEvaluator()
        XCTAssertTrue(evaluator.evaluate([window(0.85)]).isEmpty)
        XCTAssertTrue(evaluator.evaluate([window(0.86)]).isEmpty)
    }

    func testEachThresholdFiresOncePerPeriod() {
        var evaluator = AIUsageLimitAlertEvaluator()
        XCTAssertTrue(evaluator.evaluate([window(0.5)]).isEmpty)
        XCTAssertEqual(evaluator.evaluate([window(0.81)]).map { $0.threshold }, [0.8])
        XCTAssertTrue(evaluator.evaluate([window(0.9)]).isEmpty)
        XCTAssertEqual(evaluator.evaluate([window(0.97)]).map { $0.threshold }, [0.95])
        XCTAssertTrue(evaluator.evaluate([window(0.99)]).isEmpty)
        // A new period (new reset time) can alert again.
        XCTAssertEqual(evaluator.evaluate([window(0.82, reset: 2_000_000)]).map { $0.threshold }, [0.8])
    }

    func testJumpPastBothThresholdsReportsTheHighestOnce() {
        var evaluator = AIUsageLimitAlertEvaluator()
        _ = evaluator.evaluate([window(0.1)])
        XCTAssertEqual(evaluator.evaluate([window(0.96)]).map { $0.threshold }, [0.95])
    }
}

private struct StubAIUsageProvider: AIUsageProviding {
    var result: Result<AIUsageSnapshot, AIUsageError>
    func fetch(now: Date) async throws -> AIUsageSnapshot { try result.get() }
}

@MainActor
final class AIUsageModuleStoreTests: XCTestCase {
    private let snapshot = AIUsageSnapshot(
        summary: AIUsageSummary(today: AIUsageTotals(tokens: 125_161_550, costUSD: 19.54, conversations: 218)),
        limits: AIUsageLimits(windows: [
            AIUsageLimitWindow(id: "claude.five_hour", provider: "claude", providerName: "Claude",
                               windowLabel: "5h", fraction: 0.23, resetsAt: nil),
            AIUsageLimitWindow(id: "claude.seven_day", provider: "claude", providerName: "Claude",
                               windowLabel: "7d", fraction: 0.41, resetsAt: nil),
        ], issues: []),
        fetchedAt: Date(timeIntervalSince1970: 1_000)
    )

    func testCompactValueFollowsMetric() async {
        var metric = AIUsageCompactMetric.todayCost
        let store = AIUsageModuleStore(
            makeProvider: { [snapshot] in StubAIUsageProvider(result: .success(snapshot)) },
            isSelectedAndExpanded: { false },
            compactMetric: { metric },
            alertsEnabled: { true }
        )
        XCTAssertNil(store.compactValue)
        store.start()
        await store.refresh()
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.compactValue, "$19.5")
        metric = .tightestLimit
        XCTAssertEqual(store.compactValue, "41%")
        metric = .off
        XCTAssertNil(store.compactValue)
        XCTAssertNil(store.compactSummary)
        store.stop()
        metric = .todayCost
        XCTAssertNil(store.compactValue)
    }

    func testConnectionFailureMeansTokenTrackerIsNotRunning() async {
        let store = AIUsageModuleStore(
            makeProvider: { StubAIUsageProvider(result: .failure(.notRunning)) },
            isSelectedAndExpanded: { false },
            compactMetric: { .todayCost },
            alertsEnabled: { true }
        )
        store.start()
        await store.refresh()
        XCTAssertEqual(store.status, .notRunning)
        XCTAssertNil(store.compactValue)
        store.stop()
    }
}
