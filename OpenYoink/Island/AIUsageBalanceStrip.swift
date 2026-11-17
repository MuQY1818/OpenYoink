import SwiftUI

/// Balance strip at the bottom of the AI usage module: one row per configured
/// source, styled to match the surrounding TokenTracker data.
struct BalanceStripView: View {
    let entries: [BalanceEntry]
    let balances: [UUID: Result<BalanceSnapshot, BalanceFetchError>]
    /// Called when the user clicks a source's name to re-query just that
    /// balance. Nil keeps the rows read-only.
    var onRefresh: ((BalanceEntry) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(entries) { entry in
                BalanceRowView(
                    entry: entry,
                    result: balances[entry.id],
                    onRefresh: onRefresh.map { refresh in { refresh(entry) } }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Balances"))
    }
}

/// One balance source. The name doubles as a refresh button: hovering reveals a
/// small glyph, clicking re-queries that entry immediately.
private struct BalanceRowView: View {
    let entry: BalanceEntry
    let result: Result<BalanceSnapshot, BalanceFetchError>?
    let onRefresh: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            name
            Spacer(minLength: 8)
            value
        }
    }

    @ViewBuilder
    private var name: some View {
        if let onRefresh {
            Button(action: onRefresh) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .lineLimit(1)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(hovering ? 0.75 : 0)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.68))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .onHover { hovering = $0 }
            .help(Text("Refresh \(entry.name) balance"))
            .accessibilityLabel(Text("Refresh \(entry.name) balance"))
        } else {
            Text(entry.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var value: some View {
        switch result {
        case .success(let snapshot):
            Text("\(Self.currencySymbol(snapshot.currency))\(snapshot.formattedAmount)")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        case .failure(let error):
            Text(error.message)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        case nil:
            Text("…")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
        }
    }

    private static func currencySymbol(_ code: String) -> String {
        switch code {
        case "CNY": "¥"
        case "USD": "$"
        case "EUR": "€"
        case "JPY": "¥"
        case "GBP": "£"
        default: "\(code) "
        }
    }
}

private extension BalanceSnapshot {
    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }
}
