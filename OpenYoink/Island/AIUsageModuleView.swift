import AppKit
import SwiftUI

struct IslandAIUsageView: View {
    @Environment(AIUsageModuleStore.self) private var store

    var body: some View {
        VStack(spacing: 9) {
            IslandModuleHeader(
                title: "AI Usage",
                subtitle: subtitle,
                systemImage: AIUsageModuleStore.moduleDescriptor.systemImage
            )
            .overlay(alignment: .trailing) {
                if store.status == .ready { dashboardButton }
            }

            switch store.status {
            case .notRunning:
                notRunningState
            case let .failed(message) where store.snapshot == nil:
                IslandEmptyState(title: "Can't read TokenTracker",
                                 message: LocalizedStringKey(message),
                                 systemImage: "exclamationmark.triangle")
            default:
                if let snapshot = store.snapshot {
                    content(snapshot)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { store.refreshIfStale() }
    }

    private var subtitle: String {
        guard let fetchedAt = store.snapshot?.fetchedAt, store.status == .ready else {
            return String(localized: "Powered by TokenTracker")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.unitsStyle = .short
        let age = Date().timeIntervalSince(fetchedAt) < 60
            ? String(localized: "just now")
            : formatter.localizedString(for: fetchedAt, relativeTo: Date())
        return String(localized: "TokenTracker · updated \(age)")
    }

    // MARK: Content

    private func content(_ snapshot: AIUsageSnapshot) -> some View {
        let summary = snapshot.summary
        return VStack(alignment: .leading, spacing: 11) {
            todayHero(summary.today)
            hairline
            periodStrip(summary)
            if let limits = snapshot.limits, !limits.windows.isEmpty || !limits.issues.isEmpty {
                hairline
                limitsList(limits, now: snapshot.fetchedAt)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    /// Today's spend is the headline; tokens and conversations sit beside it.
    private func todayHero(_ today: AIUsageTotals) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                caption("Today")
                Text(AIUsageFormat.cost(today.costUSD))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(AIUsageFormat.tokens(today.tokens)) tokens")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                if let conversations = today.conversations {
                    Text("\(conversations) conversations")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func periodStrip(_ summary: AIUsageSummary) -> some View {
        HStack(spacing: 0) {
            period("Last 7 days", isFirst: true,
                   value: summary.last7dTokens.map { AIUsageFormat.tokens($0) },
                   detail: summary.last7dActiveDays.map { String(localized: "\($0) active days") })
            divider
            period("Last 30 days",
                   value: summary.last30dTokens.map { AIUsageFormat.tokens($0) },
                   detail: summary.last30dAveragePerActiveDay.map {
                       String(localized: "\(AIUsageFormat.tokens($0)) per day")
                   })
            divider
            period("All time",
                   value: summary.total.map { AIUsageFormat.tokens($0.tokens) },
                   detail: summary.total.map { AIUsageFormat.cost($0.costUSD) })
        }
    }

    private func period(_ title: LocalizedStringKey, isFirst: Bool = false,
                        value: String?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            caption(title)
            Text(value ?? "--")
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail ?? " ")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only columns after a divider need breathing room; the first one
        // lines up with "Today" and the limit rows.
        .padding(.leading, isFirst ? 0 : 12)
    }

    private func limitsList(_ limits: AIUsageLimits, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(limits.windows) { window in
                limitRow(window, now: now)
            }
            if !limits.issues.isEmpty {
                issuesNote(limits.issues)
            }
        }
    }

    /// One line per window: name, a thin bar in the provider's color, the
    /// percentage and when it resets.
    private func limitRow(_ window: AIUsageLimitWindow, now: Date) -> some View {
        let tint = limitTint(window)
        return HStack(spacing: 9) {
            Text(window.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * min(1, window.fraction)))
                }
            }
            .frame(height: 5)
            Text(AIUsageFormat.percent(window.fraction))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(window.fraction >= 0.8 ? tint : .white.opacity(0.9))
                .frame(width: 34, alignment: .trailing)
            Text(AIUsageFormat.shortReset(window.resetsAt, now: now) ?? "")
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.36))
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(height: 16)
        .help(AIUsageFormat.reset(window.resetsAt, now: now) ?? window.title)
        .accessibilityElement(children: .combine)
    }

    private func issuesNote(_ issues: [AIUsageLimitIssue]) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
            Text("\(issues.count) tools unavailable")
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.32))
        .help(issues.map { "\($0.providerName): \($0.message)" }.joined(separator: "\n"))
    }

    /// Opens TokenTracker's local dashboard; the subtitle already credits it.
    private var dashboardButton: some View {
        Button {
            store.openDashboard()
        } label: {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Open TokenTracker's dashboard in the browser"))
        .accessibilityLabel(Text("Open Dashboard"))
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .textCase(.uppercase)
            .tracking(0.4)
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5, height: 34)
    }

    // MARK: Not running

    private var notRunningState: some View {
        let installed = store.isTokenTrackerInstalled
        return VStack(spacing: 10) {
            IslandEmptyState(
                title: installed ? "TokenTracker isn't running" : "Get TokenTracker",
                message: installed
                    ? "Open TokenTracker and your AI usage shows up here."
                    : "AI usage comes from TokenTracker, a free, open-source tracker for Claude Code, Codex, Cursor and more.",
                systemImage: AIUsageModuleStore.moduleDescriptor.systemImage
            )
            .frame(maxHeight: 130)
            HStack(spacing: 8) {
                Button(installed ? "Open TokenTracker" : "Download TokenTracker") {
                    store.openTokenTracker()
                }
                .buttonStyle(IslandCapsuleButtonStyle(prominent: true))
                Button("Retry") { store.requestRefresh() }
                    .buttonStyle(IslandCapsuleButtonStyle(prominent: false))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Style

    /// Provider color, overridden by orange / red as a window fills up.
    private func limitTint(_ window: AIUsageLimitWindow) -> Color {
        if window.fraction >= 0.9 { return Color(red: 1.0, green: 0.36, blue: 0.33) }
        if window.fraction >= 0.75 { return Color(red: 1.0, green: 0.62, blue: 0.24) }
        switch window.provider {
        case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": return Color(red: 0.36, green: 0.78, blue: 0.62)
        case "gemini": return Color(red: 0.42, green: 0.6, blue: 1.0)
        case "copilot": return Color(red: 0.66, green: 0.52, blue: 1.0)
        case "cursor": return Color.white.opacity(0.8)
        default: return Color(red: 0.45, green: 0.7, blue: 1.0)
        }
    }
}

/// Small capsule button for the dark Island surface.
private struct IslandCapsuleButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(prominent ? Color.white.opacity(configuration.isPressed ? 0.75 : 0.92)
                                         : Color.white.opacity(configuration.isPressed ? 0.16 : 0.10))
            )
            .contentShape(Capsule())
    }
}
