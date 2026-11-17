import Foundation
import Observation
import OSLog

/// A configured balance source. The API key itself lives in the Keychain
/// (`APIKeyStore`), referenced here by the entry's UUID only.
struct BalanceEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: BalanceKind
    var name: String
    /// Base URL for OpenAI-compatible relay stations ("https://api.example.com").
    /// Empty for DeepSeek, whose endpoint is fixed.
    var baseURL: String

    init(id: UUID = UUID(), kind: BalanceKind, name: String, baseURL: String = "") {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
    }
}

enum BalanceKind: String, Codable, CaseIterable, Sendable {
    /// DeepSeek official platform balance endpoint.
    case deepSeek
    /// one-api / new-api style relays exposing the OpenAI-compatible
    /// subscription + usage billing endpoints.
    case openAICompatible
}

struct BalanceSnapshot: Equatable, Sendable {
    let amount: Double
    let currency: String
    let fetchedAt: Date
}

enum BalanceFetchError: Error, Equatable, Sendable {
    case invalidURL
    case missingKey
    case badStatus(Int)
    case parsing
    case network(String)

    var message: String {
        switch self {
        case .invalidURL:
            String(localized: "The base URL is invalid.")
        case .missingKey:
            String(localized: "No API key saved for this entry.")
        case let .badStatus(status):
            // Relays commonly return 401 for a wrong key and 403 when the
            // billing endpoints are disabled by the operator.
            status == 401 ? String(localized: "The API key was rejected (401).")
                : status == 403 ? String(localized: "This relay doesn't allow balance queries (403).")
                : String(localized: "Server error \(status).")
        case .parsing:
            String(localized: "Couldn't read the balance response.")
        case let .network(reason):
            String(localized: "Network error: \(reason)")
        }
    }
}

/// Pure response parsing, unit-testable without any network.
enum BalanceParsing {
    /// DeepSeek `GET /user/balance` → first balance_infos entry.
    static func deepSeek(data: Data, now: Date) throws -> BalanceSnapshot {
        struct Response: Decodable {
            struct Info: Decodable {
                let currency: String
                let total_balance: String
            }
            let balance_infos: [Info]?
        }
        let response = try? JSONDecoder().decode(Response.self, from: data)
        guard let info = response?.balance_infos?.first,
              let amount = Double(info.total_balance) else {
            throw BalanceFetchError.parsing
        }
        return BalanceSnapshot(amount: amount, currency: info.currency, fetchedAt: now)
    }

    /// Sub2API-style relay: `GET /v1/usage` returns the key's own remaining
    /// balance directly (`remaining`, or `balance`, plus `unit`).
    static func sub2apiUsage(data: Data, now: Date) throws -> BalanceSnapshot {
        struct Response: Decodable {
            let remaining: Double?
            let balance: Double?
            let unit: String?
        }
        let response = try? JSONDecoder().decode(Response.self, from: data)
        guard let amount = response?.remaining ?? response?.balance else {
            throw BalanceFetchError.parsing
        }
        return BalanceSnapshot(amount: amount, currency: response?.unit ?? "USD", fetchedAt: now)
    }

    /// OpenAI-compatible pair: subscription (total) minus usage (spent).
    /// `total_usage` is in US cents, matching the legacy OpenAI billing API.
    static func openAICompatible(subscription: Data, usage: Data, now: Date) throws -> BalanceSnapshot {
        struct Subscription: Decodable {
            let hard_limit_usd: Double?
        }
        struct Usage: Decodable {
            let total_usage: Double?
        }
        let sub = try? JSONDecoder().decode(Subscription.self, from: subscription)
        let use = try? JSONDecoder().decode(Usage.self, from: usage)
        guard let limit = sub?.hard_limit_usd, let spentCents = use?.total_usage else {
            throw BalanceFetchError.parsing
        }
        return BalanceSnapshot(amount: limit - spentCents / 100,
                               currency: "USD", fetchedAt: now)
    }

    /// Accepts full base URLs with or without a trailing "/v1" or "/".
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/v1") { trimmed = String(trimmed.dropLast(3)) }
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http",
              url.host != nil else { return nil }
        return url
    }
}

/// Holds the configured entries and their last-known balances. Entries persist
/// to UserDefaults (key material excluded); balances are cached in memory with
/// a refresh interval long enough to stay friendly to relay rate limits.
@MainActor
@Observable
final class BalanceStore {
    static let refreshInterval: TimeInterval = 30

    private(set) var entries: [BalanceEntry] = []
    private(set) var balances: [UUID: Result<BalanceSnapshot, BalanceFetchError>] = [:]
    private(set) var isRefreshing = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyStore: APIKeyStore
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let fetch: @Sendable (BalanceEntry, String) async -> Result<BalanceSnapshot, BalanceFetchError>

    static let entriesKey = "OpenYoink.balanceEntries"

    init(defaults: UserDefaults = .standard,
         keyStore: APIKeyStore = APIKeyStore(),
         now: @escaping () -> Date = Date.init,
         fetch: @escaping @Sendable (BalanceEntry, String) async -> Result<BalanceSnapshot, BalanceFetchError> = { entry, key in
             await BalanceFetcher.fetch(entry, apiKey: key)
         }) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.now = now
        self.fetch = fetch
        if let data = defaults.data(forKey: Self.entriesKey),
           let decoded = try? JSONDecoder().decode([BalanceEntry].self, from: data) {
            entries = decoded
        }
    }

    // MARK: Entries

    func add(_ entry: BalanceEntry) {
        entries.append(entry)
        persist()
        refresh(entry: entry)
    }

    func update(_ entry: BalanceEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persist()
        balances[entry.id] = nil
        refresh(entry: entry)
    }

    /// Saves an edited entry, adding it when it is not in the list yet. The
    /// store decides, so a stale "is new" flag from the UI can't drop a save.
    /// The key is written before the refresh so the first fetch can use it.
    func upsert(_ entry: BalanceEntry, apiKey: String?) {
        if let key = apiKey, !key.isEmpty {
            keyStore.setKey(key, for: entry.id)
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        persist()
        balances[entry.id] = nil
        refresh(entry: entry)
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        balances[id] = nil
        keyStore.deleteKey(for: id)
        persist()
    }

    func setKey(_ key: String, for id: UUID) {
        keyStore.setKey(key, for: id)
        refresh(entry: entries.first { $0.id == id })
    }

    func hasKey(for id: UUID) -> Bool {
        keyStore.key(for: id) != nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.entriesKey)
        }
    }

    // MARK: Refresh

    /// Refreshes stale balances; called when the AI usage module appears and on
    /// every tick of the module's visibility timer, so the strip stays current
    /// while it is on screen.
    func refreshIfStale() {
        let date = now()
        if isRefreshing { return }
        if let lastRefresh, date.timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        guard !entries.isEmpty else { return }
        refreshAll()
    }

    func refreshAll() {
        guard !isRefreshing else { return }
        refreshTask?.cancel()
        isRefreshing = true
        lastRefresh = now()
        let targets = entries
        refreshTask = Task { [weak self, fetch, keyStore] in
            for entry in targets {
                guard !Task.isCancelled else { break }
                let apiKey = keyStore.key(for: entry.id) ?? ""
                let result = await fetch(entry, apiKey)
                guard let self, !Task.isCancelled else { break }
                self.balances[entry.id] = result
            }
            guard let self, !Task.isCancelled else { return }
            self.isRefreshing = false
        }
    }

    /// Re-queries a single entry immediately. Also restarts the periodic
    /// countdown: a manual (or add/edit) refresh counts as "fresh data at this
    /// instant", so the automatic cycle waits a full interval instead of firing
    /// right on its heels.
    func refresh(entry: BalanceEntry?) {
        guard let entry else { return }
        lastRefresh = now()
        let apiKey = keyStore.key(for: entry.id) ?? ""
        let store = self
        Task {
            let result = await fetch(entry, apiKey)
            store.balances[entry.id] = result
        }
    }
}

// MARK: - Fetching

/// Network adapters for the two supported kinds. Errors map onto
/// `BalanceFetchError` so the UI can explain what went wrong.
enum BalanceFetcher {
    static func fetch(_ entry: BalanceEntry, apiKey: String) async -> Result<BalanceSnapshot, BalanceFetchError> {
        guard !apiKey.isEmpty else { return .failure(.missingKey) }
        do {
            switch entry.kind {
            case .deepSeek:
                let url = URL(string: "https://api.deepseek.com/user/balance")!
                let data = try await get(url, apiKey: apiKey)
                return .success(try BalanceParsing.deepSeek(data: data, now: Date()))
            case .openAICompatible:
                guard let base = BalanceParsing.normalizedBaseURL(entry.baseURL) else {
                    return .failure(.invalidURL)
                }
                // Sub2API relays expose the key's remaining balance at
                // /v1/usage; one-api/new-api relays don't have that shape, so
                // fall through to the subscription-minus-usage pair.
                if let usageData = try? await get(base.appendingPathComponent("v1/usage"),
                                                  apiKey: apiKey),
                   let snapshot = try? BalanceParsing.sub2apiUsage(data: usageData, now: Date()) {
                    return .success(snapshot)
                }
                let startDate = DateFormatter.balanceDate(Date(timeIntervalSinceNow: -86_400 * 365))
                let endDate = DateFormatter.balanceDate(Date().addingTimeInterval(60))
                let subURL = base.appendingPathComponent("v1/dashboard/billing/subscription")
                let usageURL = base.appendingPathComponent("v1/dashboard/billing/usage")
                var parts = URLComponents(url: usageURL, resolvingAgainstBaseURL: false)!
                parts.queryItems = [
                    URLQueryItem(name: "start_date", value: startDate),
                    URLQueryItem(name: "end_date", value: endDate),
                ]
                async let subData = get(subURL, apiKey: apiKey)
                async let usageData2 = get(parts.url!, apiKey: apiKey)
                return .success(try BalanceParsing.openAICompatible(
                    subscription: try await subData, usage: try await usageData2, now: Date()))
            }
        } catch let error as BalanceFetchError {
            return .failure(error)
        } catch let error as URLError {
            return .failure(.network(error.localizedDescription))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private static func get(_ url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw BalanceFetchError.badStatus(status) }
        return data
    }
}

private extension DateFormatter {
    /// The legacy billing API expects "YYYY-MM-DD".
    static let balanceDateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func balanceDate(_ date: Date) -> String {
        balanceDateFormat.string(from: date)
    }
}
