import SwiftUI

struct IslandFocusHistoryView: View {
    private struct Cell: Equatable {
        let date: Date
        let period: IslandFocusPeriod
    }

    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weekOffset = 0
    @State private var hoveredCell: Cell?
    @State private var selectedCell: Cell?

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            focusSummary

            VStack(spacing: 10) {
                weekNavigation
                heatmap
                heatmapLegend
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
    }

    private var focusSummary: some View {
        let cell = hoveredCell ?? selectedCell
        let summaryDate = cell?.date ?? Date()
        let summaryPeriod = cell?.period
        let duration = IslandFocusStatistics.duration(
            timerStore.sessions,
            on: summaryDate,
            period: summaryPeriod,
            calendar: calendar
        )
        let sessionCount = IslandFocusStatistics.sessions(
            timerStore.sessions,
            on: summaryDate,
            period: summaryPeriod,
            calendar: calendar
        ).count
        let summaryTint = summaryPeriod?.tint ?? focusGreen

        return VStack(alignment: .leading, spacing: 5) {
            Text(summaryTitle(for: cell))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(summaryTint)
                .textCase(.uppercase)
                .lineLimit(1)

            Text(focusDurationText(duration))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandVisualStyle.primaryText)
                .monospacedDigit()
                .contentTransition(.numericText())

            Label(
                String.localizedStringWithFormat(
                    String(localized: "%lld focus sessions"),
                    sessionCount
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(IslandVisualStyle.secondaryText)
            .lineLimit(1)

            Label(
                String.localizedStringWithFormat(
                    String(localized: "%lld day streak"),
                    IslandFocusStatistics.currentStreak(
                        timerStore.sessions,
                        at: Date(),
                        calendar: calendar
                    )
                ),
                systemImage: "flame.fill"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(focusGreen)
            .lineLimit(1)

            if timerStore.sessions.isEmpty {
                Text("Complete a focus session to start your map.")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(width: 136, alignment: .leading)
        .frame(minHeight: 138, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay {
                    LinearGradient(
                        colors: [summaryTint.opacity(0.11), .clear, .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16,
                                                style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
                }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: cell)
    }

    private var weekNavigation: some View {
        HStack(spacing: 6) {
            Button {
                changeWeek(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(Text("Previous week"))

            Spacer(minLength: 0)

            Text(weekRangeText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .monospacedDigit()
                .contentTransition(.numericText())

            Spacer(minLength: 0)

            Button {
                changeWeek(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
            .disabled(weekOffset >= 0)
            .opacity(weekOffset >= 0 ? 0.26 : 1)
            .accessibilityLabel(Text("Next week"))
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(IslandVisualStyle.secondaryText)
    }

    private var heatmap: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(spacing: 4) {
                Color.clear.frame(width: 18, height: 12)
                ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                    Image(systemName: period.systemImage)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(period.tint.opacity(0.78))
                        .frame(width: 18, height: 25)
                        .accessibilityHidden(true)
                }
            }

            ForEach(Array(weekDays.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 4) {
                    Text(day, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(calendar.isDateInToday(day)
                                         ? Color.white
                                         : IslandVisualStyle.tertiaryText)
                        .frame(height: 12)

                    ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                        heatCell(day: day, period: period)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var heatmapLegend: some View {
        HStack(spacing: 10) {
            ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                Label(period.title, systemImage: period.systemImage)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(period.tint.opacity(0.76))
            }
            Spacer(minLength: 0)
            Text("Focus time")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(IslandVisualStyle.tertiaryText)
        }
        .lineLimit(1)
    }

    private func heatCell(day: Date, period: IslandFocusPeriod) -> some View {
        let cell = Cell(date: day, period: period)
        let duration = IslandFocusStatistics.duration(
            timerStore.sessions,
            on: day,
            period: period,
            calendar: calendar
        )
        let count = IslandFocusStatistics.sessions(
            timerStore.sessions,
            on: day,
            period: period,
            calendar: calendar
        ).count
        let isHighlighted = hoveredCell == cell || selectedCell == cell
        let intensity = min(max(duration / 3_600, 0), 1)

        return Button {
            selectedCell = selectedCell == cell ? nil : cell
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(duration > 0
                      ? period.tint.opacity(0.20 + intensity * 0.72)
                      : Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHighlighted
                                ? Color.white.opacity(0.78)
                                : Color.white.opacity(duration > 0 ? 0.12 : 0.045),
                            lineWidth: isHighlighted ? 1.2 : 1
                        )
                }
                .shadow(color: duration > 0
                        ? period.tint.opacity(0.16 + intensity * 0.18)
                        : .clear,
                        radius: 4)
                .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25)
                .scaleEffect(isHighlighted && !reduceMotion ? 1.055 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredCell = hovering ? cell : (hoveredCell == cell ? nil : hoveredCell)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14),
                   value: isHighlighted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(cellAccessibilityLabel(cell)))
        .accessibilityValue(Text(
            String.localizedStringWithFormat(
                String(localized: "%lld focus sessions"),
                count
            ) + ", " + focusDurationText(duration)
        ))
        .modifier(IslandSelectedAccessibilityModifier(selected: selectedCell == cell))
    }

    private var weekStart: Date {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .weekOfYear,
                             value: weekOffset,
                             to: currentWeek) ?? currentWeek
    }

    private var weekDays: [Date] {
        (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: weekStart)
        }
    }

    private var weekRangeText: String {
        guard let end = weekDays.last else { return "" }
        let startText = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let endText = end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    private func changeWeek(by amount: Int) {
        let target = min(0, weekOffset + amount)
        if reduceMotion {
            weekOffset = target
        } else {
            withAnimation(.smooth(duration: 0.24)) {
                weekOffset = target
            }
        }
        hoveredCell = nil
        selectedCell = nil
    }

    private func summaryTitle(for cell: Cell?) -> String {
        guard let cell else { return String(localized: "Today") }
        let date = cell.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) · \(cell.period.title)"
    }

    private func cellAccessibilityLabel(_ cell: Cell) -> String {
        let date = cell.date.formatted(.dateTime.year().month().day().weekday(.wide))
        return "\(date), \(cell.period.title)"
    }

    private func focusDurationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration.rounded() / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private var focusGreen: Color {
        Color(red: 0.22, green: 0.86, blue: 0.48)
    }
}

private extension IslandFocusPeriod {
    var title: String {
        switch self {
        case .morning: String(localized: "Morning")
        case .afternoon: String(localized: "Afternoon")
        case .evening: String(localized: "Evening")
        }
    }

    var systemImage: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        }
    }

    var tint: Color {
        switch self {
        case .morning: Color(red: 1.0, green: 0.70, blue: 0.34)
        case .afternoon: Color(red: 0.22, green: 0.86, blue: 0.48)
        case .evening: Color(red: 0.66, green: 0.43, blue: 0.98)
        }
    }
}
