import AppKit
import CFNetwork
import Foundation
import Observation

// AI usage module. Token usage, spend and plan limits come from TokenTracker
// (https://github.com/xiufengsun/TokenTracker, MIT), which serves a local API
// on localhost:7680 from its menu bar app or `tokentracker serve`. OpenYoink
// only reads that API. It never parses tool logs itself (the sandbox cannot
// read them anyway) and never triggers a sync.

// MARK: - Models

struct AIUsageTotals: Equatable, Sendable {
    var tokens: Int
    var costUSD: Double?
    var conversations: Int?
}

struct AIUsageSummary: Equatable, Sendable {
    var today: AIUsageTotals
    var last7dTokens: Int?
    var last7dActiveDays: Int?
    var last30dTokens: Int?
    var last30dAveragePerActiveDay: Int?
    var total: AIUsageTotals?
}

struct AIUsageLimitWindow: Identifiable, Equatable, Sendable {
    /// `provider.window`, stable across refreshes.
    let id: String
    let provider: String
    let providerName: String
    let windowLabel: String?
    /// 0...1 (can exceed 1 when a provider reports overage).
    let fraction: Double
    let resetsAt: Date?

    var title: String {
        guard let windowLabel, !windowLabel.isEmpty else { return providerName }
        return "\(providerName) · \(windowLabel)"
    }
}

struct AIUsageLimitIssue: Identifiable, Equatable, Sendable {
    let provider: String
    let providerName: String
    let message: String
    var id: String { provider }
}

struct AIUsageLimits: Equatable, Sendable {
    var windows: [AIUsageLimitWindow]
    var issues: [AIUsageLimitIssue]

    static let empty = AIUsageLimits(windows: [], issues: [])

    /// The window closest to its cap.
    var tightestWindow: AIUsageLimitWindow? {
        windows.max { $0.fraction < $1.fraction }
    }
}

struct AIUsageSnapshot: Equatable, Sendable {
    var summary: AIUsageSummary
    /// nil when the limits endpoint failed; usage numbers still show.
    var limits: AIUsageLimits?
    var fetchedAt: Date
}

enum AIUsageCompactMetric: String, CaseIterable, Identifiable, Sendable {
    case off
    case todayCost
    case todayTokens
    case tightestLimit

    var id: String { rawValue }
}

// MARK: - Summary decoding

/// `total_cost_usd` arrives as a decimal string ("19.544926"); accept numbers too.
struct AIUsageFlexibleDouble: Decodable, Equatable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self) {
            value = Double(string)
        } else {
            value = nil
        }
    }
}

struct TokenTrackerSummaryResponse: Decodable, Sendable {
    struct Totals: Decodable, Sendable {
        var totalTokens: Int?
        var billableTotalTokens: Int?
        var totalCostUsd: AIUsageFlexibleDouble?
        var conversationCount: Int?
    }

    struct RollingWindow: Decodable, Sendable {
        var activeDays: Int?
        var avgPerActiveDay: Int?
        var totals: Totals?
    }

    struct Rolling: Decodable, Sendable {
        var last7d: RollingWindow?
        var last30d: RollingWindow?

        // `.convertFromSnakeCase` turns "last_7d" into "last7D" ("7d".capitalized).
        enum CodingKeys: String, CodingKey {
            case last7d = "last7D"
            case last30d = "last30D"
        }
    }

    var totals: Totals?
    var rolling: Rolling?

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }

    var asTotals: AIUsageTotals {
        AIUsageTotals(
            tokens: totals?.totalTokens ?? totals?.billableTotalTokens ?? 0,
            costUSD: totals?.totalCostUsd?.value,
            conversations: totals?.conversationCount
        )
    }
}

// MARK: - Limits parsing

/// Flattens `/tokentracker-usage-limits` into labelled windows. Providers
/// expose different window keys and units; the mapping follows TokenTracker's
/// own widget so both apps show the same labels.
enum AIUsageLimitsParser {
    private static let skippedKeys: Set<String> = ["extra_usage", "provenance"]

    static func parse(_ data: Data) throws -> AIUsageLimits {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageError.decoding
        }
        var windows: [AIUsageLimitWindow] = []
        var issues: [AIUsageLimitIssue] = []
        for provider in root.keys.sorted(by: providerOrder) {
            guard let body = root[provider] as? [String: Any],
                  body["configured"] as? Bool == true else { continue }
            let name = providerName(provider)
            var providerWindows: [AIUsageLimitWindow] = []
            for key in body.keys.sorted(by: windowOrder) where !skippedKeys.contains(key) {
                if let window = body[key] as? [String: Any],
                   let parsed = makeWindow(window, provider: provider, providerName: name,
                                           key: key, label: windowLabel(provider: provider, key: key, body: body)) {
                    providerWindows.append(parsed)
                } else if let scoped = body[key] as? [[String: Any]] {
                    // Claude `weekly_scoped`: [{label, utilization, resets_at}]
                    for (index, window) in scoped.enumerated() {
                        let scope = window["label"] as? String
                        let label = [AIUsageLabels.sevenDay, scope].compactMap { $0 }.joined(separator: " ")
                        if let parsed = makeWindow(window, provider: provider, providerName: name,
                                                   key: "\(key).\(index)", label: label) {
                            providerWindows.append(parsed)
                        }
                    }
                }
            }
            if providerWindows.isEmpty,
               let message = body["error"] as? String, !message.isEmpty {
                issues.append(AIUsageLimitIssue(provider: provider, providerName: name, message: message))
            }
            windows.append(contentsOf: providerWindows)
        }
        return AIUsageLimits(windows: windows, issues: issues)
    }

    private static func makeWindow(_ window: [String: Any], provider: String, providerName: String,
                                   key: String, label: String?) -> AIUsageLimitWindow? {
        guard let percent = number(window["utilization"]) ?? number(window["used_percent"]) else {
            return nil
        }
        let reset = date(window["resets_at"]) ?? date(window["reset_at"])
        return AIUsageLimitWindow(id: "\(provider).\(key)", provider: provider,
                                  providerName: providerName, windowLabel: label,
                                  fraction: max(0, percent / 100), resetsAt: reset)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(number is Bool): number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    /// ISO 8601 strings (with any number of fractional digits) or Unix seconds.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(number is Bool) {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard var string = value as? String, !string.isEmpty else { return nil }
        if let dot = string.firstIndex(of: ".") {
            let digits = string[string.index(after: dot)...].prefix { $0.isNumber }
            string.removeSubrange(dot..<string.index(dot, offsetBy: digits.count + 1))
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private static let knownProviders: [String: String] = [
        "claude": "Claude", "codex": "Codex", "cursor": "Cursor", "gemini": "Gemini",
        "kimi": "Kimi", "kiro": "Kiro", "antigravity": "Antigravity", "copilot": "Copilot",
        "grok": "Grok Build", "zcode": "ZCode", "opencodeGo": "OpenCode Go",
        "commandCode": "Command Code", "devin": "Devin", "qoder": "Qoder", "qoderCn": "Qoder CN",
        "codingPlan": "Coding Plan", "agentPlan": "Agent Plan", "workbuddy": "WorkBuddy",
        "workbuddyAi": "WorkBuddy AI", "deepseek": "DeepSeek",
    ]
    private static let providerRank = ["claude", "codex", "cursor", "gemini", "copilot"]

    static func providerName(_ key: String) -> String {
        if let name = knownProviders[key] { return name }
        guard let first = key.first else { return key }
        return first.uppercased() + key.dropFirst()
    }

    private static func providerOrder(_ lhs: String, _ rhs: String) -> Bool {
        let l = providerRank.firstIndex(of: lhs) ?? providerRank.count
        let r = providerRank.firstIndex(of: rhs) ?? providerRank.count
        return l != r ? l < r : lhs < rhs
    }

    private static let windowRank = [
        "five_hour", "seven_day", "seven_day_opus", "weekly_scoped",
        "primary_window", "secondary_window", "tertiary_window",
        "spark_primary_window", "spark_secondary_window",
    ]

    private static func windowOrder(_ lhs: String, _ rhs: String) -> Bool {
        let l = windowRank.firstIndex(of: lhs) ?? windowRank.count
        let r = windowRank.firstIndex(of: rhs) ?? windowRank.count
        return l != r ? l < r : lhs < rhs
    }

    private static func windowLabel(provider: String, key: String, body: [String: Any]) -> String? {
        switch key {
        case "five_hour": return AIUsageLabels.fiveHour
        case "seven_day": return AIUsageLabels.sevenDay
        case "seven_day_opus": return "\(AIUsageLabels.sevenDay) Opus"
        case "spark_primary_window": return "Spark \(AIUsageLabels.fiveHour)"
        case "spark_secondary_window": return "Spark \(AIUsageLabels.sevenDay)"
        default: break
        }
        let slot: Int? = switch key {
        case "primary_window": 0
        case "secondary_window": 1
        case "tertiary_window": 2
        default: nil
        }
        guard let slot else { return key.replacingOccurrences(of: "_", with: " ") }
        let labels: [String?] = switch provider {
        case "codex": [AIUsageLabels.fiveHour, AIUsageLabels.weekly]
        case "kimi": [AIUsageLabels.weekly, AIUsageLabels.fiveHour, AIUsageLabels.total]
        case "opencodeGo": [nil, AIUsageLabels.weekly, AIUsageLabels.monthly]
        case "commandCode": [nil, AIUsageLabels.weekly]
        case "devin": [AIUsageLabels.daily, AIUsageLabels.weekly]
        case "grok":
            [Self.grokPeriod(body["period_type"] as? String), AIUsageLabels.onDemand]
        default: [nil, "2", "3"]
        }
        return slot < labels.count ? labels[slot] : nil
    }

    private static func grokPeriod(_ period: String?) -> String {
        switch period {
        case "weekly": AIUsageLabels.weekly
        case "daily": AIUsageLabels.daily
        default: AIUsageLabels.monthly
        }
    }
}

enum AIUsageLabels {
    static var fiveHour: String { String(localized: "5h", comment: "AI usage limit window: five hours") }
    static var sevenDay: String { String(localized: "7d", comment: "AI usage limit window: seven days") }
    static var weekly: String { String(localized: "Weekly", comment: "AI usage limit window") }
    static var daily: String { String(localized: "Daily", comment: "AI usage limit window") }
    static var monthly: String { String(localized: "Monthly", comment: "AI usage limit window") }
    static var total: String { String(localized: "Total", comment: "AI usage limit window") }
    static var onDemand: String { String(localized: "On-demand", comment: "AI usage limit window") }
}

// MARK: - Formatting

enum AIUsageFormat {
    /// UI language, not region: the app can override `AppleLanguages`.
    static var usesChineseUnits: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
    }

    static func tokens(_ value: Int, chinese: Bool = usesChineseUnits) -> String {
        let number = Double(value)
        func trim(_ value: Double, digits: Int) -> String {
            let text = String(format: "%.\(digits)f", value)
            guard text.contains(".") else { return text }
            return text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
        func scaled(_ unit: Double) -> String {
            let value = number / unit
            return trim(value, digits: value >= 100 ? 0 : value >= 10 ? 1 : 2)
        }
        if chinese {
            if number >= 1e8 { return scaled(1e8) + " 亿" }
            if number >= 1e4 { return scaled(1e4) + " 万" }
            return "\(value)"
        }
        if number >= 1e9 { return scaled(1e9) + "B" }
        if number >= 1e6 { return scaled(1e6) + "M" }
        if number >= 1e3 { return scaled(1e3) + "K" }
        return "\(value)"
    }

    static func cost(_ value: Double?) -> String {
        guard let value else { return "--" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        let digits = value >= 1000 ? 0 : 2
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// Compact Island wing: as short as possible ("$19.5", "$1.2K").
    static func compactCost(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value >= 1000 { return String(format: "$%.1fK", value / 1000) }
        if value >= 100 { return String(format: "$%.0f", value) }
        return String(format: "$%.1f", value)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Language-neutral form for tight rows: "4h", "35m", "Wed 08:59".
    static func shortReset(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        if interval < 3600 { return "\(max(1, Int(interval / 60)))m" }
        if interval < 24 * 3600 { return "\(Int(interval / 3600))h" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return formatter.string(from: date)
    }

    static func reset(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return String(localized: "Resetting now") }
        if interval < 24 * 3600 {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = interval < 3600 ? [.minute] : [.hour, .minute]
            formatter.maximumUnitCount = 1
            var calendar = Calendar.current
            calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
            formatter.calendar = calendar
            let text = formatter.string(from: max(60, interval)) ?? ""
            return String(localized: "Resets in \(text)")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return String(localized: "Resets \(formatter.string(from: date))")
    }
}

// MARK: - Client

enum AIUsageError: Error, Equatable {
    /// Nothing is listening: TokenTracker isn't running.
    case notRunning
    case badStatus(Int)
    case decoding
}

protocol AIUsageProviding: Sendable {
    func fetch(now: Date) async throws -> AIUsageSnapshot
}

struct TokenTrackerClient: AIUsageProviding {
    static let defaultPort = 7680
    static let bundleIdentifier = "com.tokentracker.bar"
    static let projectURL = URL(string: "https://github.com/xiufengsun/TokenTracker")!
    static let downloadURL = URL(string: "https://github.com/xiufengsun/TokenTracker/releases/latest")!

    let port: Int
    private let session: URLSession

    init(port: Int = Self.defaultPort) {
        self.port = port
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // A system proxy or a TUN-mode VPN can swallow loopback requests
        // (TokenTracker issue #557). An explicit dictionary bypasses it.
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as AnyHashable: 0,
            kCFNetworkProxiesHTTPSEnable as AnyHashable: 0,
            kCFNetworkProxiesSOCKSEnable as AnyHashable: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as AnyHashable: 0,
        ]
        session = URLSession(configuration: configuration)
    }

    var dashboardURL: URL { URL(string: "http://localhost:\(port)")! }

    func fetch(now: Date) async throws -> AIUsageSnapshot {
        let calendar = Calendar.current
        let today = Self.dayString(now, calendar: calendar)
        // Matches TokenTracker's "Total" period: the first day of the month
        // 24 months ago through today.
        let monthStart = calendar.date(from: calendar.dateComponents(
            [.year, .month], from: calendar.date(byAdding: .month, value: -24, to: now) ?? now
        )) ?? now
        async let todayData = get("tokentracker-usage-summary",
                                  query: ["from": today, "to": today], now: now)
        async let totalData = get("tokentracker-usage-summary",
                                  query: ["from": Self.dayString(monthStart, calendar: calendar), "to": today],
                                  now: now)
        async let limitsData = get("tokentracker-usage-limits", query: [:], now: now)

        let todayResponse = try TokenTrackerSummaryResponse.decode(try await todayData)
        let totalResponse = try? TokenTrackerSummaryResponse.decode(try await totalData)
        let limits = try? AIUsageLimitsParser.parse(try await limitsData)
        let rolling = todayResponse.rolling
        let summary = AIUsageSummary(
            today: todayResponse.asTotals,
            last7dTokens: rolling?.last7d?.totals?.billableTotalTokens,
            last7dActiveDays: rolling?.last7d?.activeDays,
            last30dTokens: rolling?.last30d?.totals?.billableTotalTokens,
            last30dAveragePerActiveDay: rolling?.last30d?.avgPerActiveDay,
            total: totalResponse?.asTotals
        )
        return AIUsageSnapshot(summary: summary, limits: limits, fetchedAt: now)
    }

    private func get(_ function: String, query: [String: String], now: Date) async throws -> Data {
        var components = URLComponents(string: "http://localhost:\(port)/functions/\(function)")!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if function == "tokentracker-usage-summary" {
            // Same parameters TokenTracker sends, so "today" matches its dashboard.
            items += [
                URLQueryItem(name: "tz", value: TimeZone.current.identifier),
                URLQueryItem(name: "tz_offset_minutes",
                             value: String(TimeZone.current.secondsFromGMT(for: now) / 60)),
                URLQueryItem(name: "account", value: "1"),
            ]
        }
        components.queryItems = items.isEmpty ? nil : items
        do {
            let (data, response) = try await session.data(from: components.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw AIUsageError.badStatus(status) }
            return data
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
                 .notConnectedToInternet:
                throw AIUsageError.notRunning
            default:
                throw error
            }
        }
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - Policies

enum AIUsageRefreshPolicy {
    static func interval(isSelectedAndExpanded: Bool, showsCompactValue: Bool,
                         isConstrained: Bool) -> Duration {
        let base: Duration = isSelectedAndExpanded ? .seconds(30)
            : showsCompactValue ? .seconds(60) : .seconds(300)
        return isConstrained ? base * 2 : base
    }
}

/// Fires once per limit window, per threshold, per reset period, and only for
/// crossings it sees happen: usage that is already high when monitoring
/// starts is recorded silently, so every launch doesn't repeat old news.
struct AIUsageLimitAlertEvaluator {
    static let thresholds: [Double] = [0.8, 0.95]

    private(set) var notified: Set<String> = []
    private(set) var hasBaseline = false

    mutating func reset() {
        notified = []
        hasBaseline = false
    }

    /// Returns the windows that newly crossed a threshold, with the highest
    /// threshold each crossed.
    mutating func evaluate(_ windows: [AIUsageLimitWindow]) -> [(window: AIUsageLimitWindow, threshold: Double)] {
        var crossed: [(AIUsageLimitWindow, Double)] = []
        for window in windows {
            let reached = Self.thresholds.filter { window.fraction >= $0 }
            guard let highest = reached.max() else { continue }
            let newKeys = reached.map { Self.key(window, $0) }.filter { !notified.contains($0) }
            guard !newKeys.isEmpty else { continue }
            notified.formUnion(newKeys)
            if hasBaseline { crossed.append((window, highest)) }
        }
        hasBaseline = true
        return crossed
    }

    private static func key(_ window: AIUsageLimitWindow, _ threshold: Double) -> String {
        // The reset date scopes the key to one period: a new period alerts again.
        let period = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-"
        return "\(window.id)|\(Int(threshold * 100))|\(period)"
    }
}

// MARK: - Store / runtime

@MainActor
@Observable
final class AIUsageModuleStore: IslandModuleRuntime {
    static let moduleDescriptor = IslandModuleDescriptor(
        id: .aiUsage,
        title: String(localized: "AI Usage"),
        systemImage: "chart.line.uptrend.xyaxis",
        order: 8,
        isCore: false
    )

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case notRunning
        case failed(String)
    }

    let descriptor = AIUsageModuleStore.moduleDescriptor
    let events: AsyncStream<IslandModuleEvent>

    private(set) var status: Status = .idle
    private(set) var snapshot: AIUsageSnapshot?
    private(set) var isRunning = false

    @ObservationIgnored private let makeProvider: @MainActor () -> any AIUsageProviding
    @ObservationIgnored private let isSelectedAndExpanded: @MainActor () -> Bool
    @ObservationIgnored private let compactMetric: @MainActor () -> AIUsageCompactMetric
    @ObservationIgnored private let alertsEnabled: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let continuation: AsyncStream<IslandModuleEvent>.Continuation
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var policyToken: NSObjectProtocol?
    @ObservationIgnored private var alertEvaluator = AIUsageLimitAlertEvaluator()

    init(
        makeProvider: @escaping @MainActor () -> any AIUsageProviding = { TokenTrackerClient() },
        isSelectedAndExpanded: @escaping @MainActor () -> Bool,
        compactMetric: @escaping @MainActor () -> AIUsageCompactMetric,
        alertsEnabled: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.makeProvider = makeProvider
        self.isSelectedAndExpanded = isSelectedAndExpanded
        self.compactMetric = compactMetric
        self.alertsEnabled = alertsEnabled
        self.now = now
        var captured: AsyncStream<IslandModuleEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured!
    }

    deinit {
        pollingTask?.cancel()
        refreshTask?.cancel()
        if let policyToken { NotificationCenter.default.removeObserver(policyToken) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        _ = ResourceUsageState.shared
        policyToken = NotificationCenter.default.addObserver(
            forName: .openYoinkResourcePolicyDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartPolling() }
        }
        restartPolling()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        if let policyToken { NotificationCenter.default.removeObserver(policyToken) }
        policyToken = nil
        alertEvaluator.reset()
        continuation.yield(.removeAllActivities)
    }

    /// Opening the module refreshes data that is older than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 20) {
        guard isRunning else { return }
        if let fetchedAt = snapshot?.fetchedAt, now().timeIntervalSince(fetchedAt) < maxAge,
           status == .ready { return }
        requestRefresh()
    }

    func requestRefresh() {
        guard isRunning else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in await self?.refresh() }
    }

    func refresh() async {
        guard isRunning, ResourceUsageState.shared.samplingAllowed else { return }
        if snapshot == nil { status = .loading }
        let provider = makeProvider()
        do {
            let next = try await provider.fetch(now: now())
            guard isRunning, !Task.isCancelled else { return }
            snapshot = next
            status = .ready
            evaluateAlerts(next.limits?.windows ?? [])
        } catch {
            guard isRunning, !Task.isCancelled else { return }
            if case AIUsageError.notRunning = error {
                status = .notRunning
            } else {
                status = .failed(Self.describe(error))
            }
        }
    }

    /// Value for the compact Island wing; nil hides it.
    var compactValue: String? {
        guard isRunning, status == .ready, let snapshot else { return nil }
        switch compactMetric() {
        case .off: return nil
        case .todayCost: return AIUsageFormat.compactCost(snapshot.summary.today.costUSD)
        case .todayTokens: return AIUsageFormat.tokens(snapshot.summary.today.tokens)
        case .tightestLimit:
            return snapshot.limits?.tightestWindow.map { AIUsageFormat.percent($0.fraction) }
        }
    }

    /// One line for the no-notch capsule.
    var compactSummary: String? {
        guard compactValue != nil, let today = snapshot?.summary.today else { return nil }
        return String(localized: "AI today \(AIUsageFormat.cost(today.costUSD)) · \(AIUsageFormat.tokens(today.tokens))")
    }

    var isTokenTrackerInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: TokenTrackerClient.bundleIdentifier) != nil
    }

    func openTokenTracker() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TokenTrackerClient.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                Task { @MainActor [weak self] in
                    // The embedded server needs a moment after launch.
                    try? await Task.sleep(for: .seconds(4))
                    self?.requestRefresh()
                }
            }
        } else {
            NSWorkspace.shared.open(TokenTrackerClient.downloadURL)
        }
    }

    func openDashboard() {
        NSWorkspace.shared.open(TokenTrackerClient().dashboardURL)
    }

    private func restartPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard isRunning, ResourceUsageState.shared.samplingAllowed else { return }
        pollingTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                await self.refresh()
                let interval = AIUsageRefreshPolicy.interval(
                    isSelectedAndExpanded: self.isSelectedAndExpanded(),
                    showsCompactValue: self.compactMetric() != .off,
                    isConstrained: ResourceUsageState.shared.isConstrained
                )
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func evaluateAlerts(_ windows: [AIUsageLimitWindow]) {
        let crossed = alertEvaluator.evaluate(windows)
        guard alertsEnabled() else { return }
        let date = now()
        for (window, threshold) in crossed {
            let percent = AIUsageFormat.percent(window.fraction)
            continuation.yield(.publishActivity(IslandActivity(
                id: "aiUsage.limit.\(window.id).\(Int(threshold * 100))",
                moduleID: .aiUsage,
                priority: .systemWarning,
                title: String(localized: "\(window.title) limit at \(percent)"),
                detail: AIUsageFormat.reset(window.resetsAt, now: date),
                systemImage: "gauge.with.dots.needle.100percent",
                expiresAt: date.addingTimeInterval(10 * 60)
            )))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case AIUsageError.badStatus(let code): String(localized: "TokenTracker returned HTTP \(code)")
        case AIUsageError.decoding, is DecodingError: String(localized: "Unexpected response from TokenTracker")
        default: error.localizedDescription
        }
    }
}
