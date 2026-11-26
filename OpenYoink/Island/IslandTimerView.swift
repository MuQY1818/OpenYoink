import SwiftUI

struct IslandTimerView: View {
    private enum Page: Hashable {
        case timer
        case history
    }

    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customMinutes = 25
    @State private var page: Page = .timer

    var body: some View {
        VStack(spacing: 10) {
            IslandModuleHeader(
                title: "Timer",
                subtitle: page == .timer
                    ? timerSubtitle
                    : String(localized: "Focus history"),
                systemImage: timerStore.mode.systemImage
            )
            .overlay(alignment: .trailing) {
                timerPageSwitcher
            }

            Group {
                if page == .timer {
                    timerControls
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    IslandFocusHistoryView()
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            customMinutes = timerStore.mode.defaultMinutes
        }
        .onChange(of: timerStore.mode) { _, mode in
            customMinutes = mode.defaultMinutes
        }
    }

    private var timerControls: some View {
        HStack(spacing: 18) {
            IslandTimerDial(
                timeText: timerDisplayText,
                stateText: timerDialState,
                systemImage: timerStateSymbol,
                remainingFraction: timerDialRemainingFraction,
                tint: timerTint,
                tick: timerStore.tick,
                isRunning: isRunning,
                reduceMotion: reduceMotion
            )
            .frame(width: 146, height: 146)

            VStack(spacing: 7) {
                if timerStore.state == .idle {
                    timerModeSelector
                    timerIntention
                    timerPresets
                    timerSetupRow
                } else {
                    timerStatusSummary
                    timerRunningControls
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
    }

    private var timerPageSwitcher: some View {
        HStack(spacing: 2) {
            timerPageButton(.timer,
                            systemImage: "timer",
                            accessibilityLabel: "Timer controls")
            timerPageButton(.history,
                            systemImage: "chart.dots.scatter",
                            accessibilityLabel: "Focus history")
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay {
            Capsule().strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
        }
    }

    private func timerPageButton(
        _ target: Page,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        let selected = page == target
        return Button {
            if reduceMotion {
                page = target
            } else {
                withAnimation(.smooth(duration: 0.26)) {
                    page = target
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.white : IslandVisualStyle.tertiaryText)
                .frame(width: 27, height: 24)
                .background {
                    if selected {
                        Capsule().fill(Color.white.opacity(0.11))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(Text(accessibilityLabel))
        .modifier(IslandSelectedAccessibilityModifier(selected: selected))
    }

    private var timerModeSelector: some View {
        HStack(spacing: 5) {
            ForEach(IslandTimerStore.Mode.allCases, id: \.self) { mode in
                let isSelected = timerStore.mode == mode
                Button {
                    timerStore.selectMode(mode)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 9, weight: .bold))
                        Text(mode.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.white : IslandVisualStyle.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        Capsule()
                            .fill(isSelected ? modeTint(mode).opacity(0.24)
                                             : IslandVisualStyle.controlFill)
                            .overlay {
                                Capsule().strokeBorder(
                                    isSelected ? modeTint(mode).opacity(0.64)
                                               : IslandVisualStyle.hairline,
                                    lineWidth: 1
                                )
                            }
                    }
                }
                .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
                .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
            }
        }
    }

    @ViewBuilder
    private var timerIntention: some View {
        if timerStore.mode == .focus {
            HStack(spacing: 7) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(timerTint)
                TextField(String(localized: "What will you focus on?"), text: goalBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.primaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(Capsule().fill(Color.white.opacity(0.065)))
            .overlay {
                Capsule().strokeBorder(timerTint.opacity(0.20), lineWidth: 1)
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: timerStore.mode.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(timerStore.mode == .shortBreak
                     ? String(localized: "Take a breath")
                     : String(localized: "Step away and recharge"))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(timerTint)
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(Capsule().fill(timerTint.opacity(0.075)))
            .overlay {
                Capsule().strokeBorder(timerTint.opacity(0.18), lineWidth: 1)
            }
        }
    }

    private var timerPresets: some View {
        HStack(spacing: 5) {
            ForEach(modePresets, id: \.self) { minutes in
                let isSelected = customMinutes == minutes
                Button {
                    if reduceMotion {
                        customMinutes = minutes
                    } else {
                        withAnimation(.snappy(duration: 0.22)) {
                            customMinutes = minutes
                        }
                    }
                } label: {
                    Text("\(minutes)m")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected
                                         ? Color.white
                                         : IslandVisualStyle.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 27)
                        .background {
                            Capsule()
                                .fill(isSelected
                                      ? AnyShapeStyle(LinearGradient(
                                        colors: [timerTint.opacity(0.92),
                                                 timerTint.opacity(0.58)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                      ))
                                      : AnyShapeStyle(IslandVisualStyle.controlFill))
                                .overlay {
                                    Capsule().strokeBorder(
                                        isSelected ? Color.white.opacity(0.20)
                                            : IslandVisualStyle.hairline,
                                        lineWidth: 1
                                    )
                                }
                        }
                }
                .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(Text("\(minutes) minutes"))
                .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
            }
        }
    }

    private var timerSetupRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                compactControlButton("minus") {
                    customMinutes = max(1, customMinutes - 1)
                }
                Text("\(customMinutes) min")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 58)
                compactControlButton("plus") {
                    customMinutes = min(180, customMinutes + 1)
                }
            }
            .padding(.horizontal, 3)
            .background(Capsule().fill(IslandVisualStyle.controlFill))

            Spacer(minLength: 4)

            Button {
                timerStore.start(minutes: Double(customMinutes))
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .frame(height: 35)
                    .background {
                        Capsule().fill(Color.white)
                    }
                    .shadow(color: timerTint.opacity(0.32), radius: 8, y: 3)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        }
    }

    private var timerStatusSummary: some View {
        HStack(spacing: 9) {
            Image(systemName: timerStateSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(timerTint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(timerTint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(timerDialState)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                Text(timerStatusDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Capsule().fill(timerTint.opacity(0.08)))
        .overlay {
            Capsule().strokeBorder(timerTint.opacity(0.16), lineWidth: 1)
        }
    }

    private var timerRunningControls: some View {
        HStack(spacing: 10) {
            timerPrimaryAction
            Button(role: .destructive) { timerStore.reset() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule().fill(IslandVisualStyle.controlFill))
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var timerSubtitle: String {
        switch timerStore.state {
        case .idle: return String(localized: "Ready to flow")
        case .running: return timerStore.mode.title
        case .paused: return String(localized: "Paused")
        case .finished: return String(localized: "Timer finished")
        }
    }

    private var timerDisplayText: String {
        if timerStore.state == .idle {
            return String(format: "%02d:00", customMinutes)
        }
        return timerStore.formattedRemaining
    }

    private var timerDialRemainingFraction: Double {
        timerStore.state == .idle ? 1 : timerStore.remainingFraction
    }

    private var isRunning: Bool {
        if case .running = timerStore.state { return true }
        return false
    }

    private var timerDialState: String {
        switch timerStore.state {
        case .idle, .running: return timerStore.mode.title
        case .paused: return String(localized: "Paused")
        case .finished: return String(localized: "Time's up")
        }
    }

    private var timerStatusDetail: String {
        let trimmedGoal = timerStore.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        switch timerStore.state {
        case .idle: return String(localized: "Ready to flow")
        case .running where timerStore.mode == .focus && !trimmedGoal.isEmpty:
            return trimmedGoal
        case .running: return String(localized: "Countdown is running")
        case .paused: return String(localized: "Continue whenever you're ready")
        case .finished: return String(localized: "Your timer is complete")
        }
    }

    private var timerStateSymbol: String {
        switch timerStore.state {
        case .idle: return timerStore.mode.systemImage
        case .running: return "hourglass.bottomhalf.filled"
        case .paused: return "pause.fill"
        case .finished: return "checkmark"
        }
    }

    private var timerTint: Color {
        switch timerStore.state {
        case .idle, .running, .paused: return modeTint(timerStore.mode)
        case .finished: return .green
        }
    }

    private var modePresets: [Int] {
        switch timerStore.mode {
        case .focus: [15, 25, 45]
        case .shortBreak: [5, 10, 15]
        case .longBreak: [15, 20, 30]
        }
    }

    private var goalBinding: Binding<String> {
        Binding(get: { timerStore.goal }, set: { timerStore.setGoal($0) })
    }

    private func modeTint(_ mode: IslandTimerStore.Mode) -> Color {
        switch mode {
        case .focus: Color(red: 0.22, green: 0.86, blue: 0.48)
        case .shortBreak: Color(red: 0.26, green: 0.67, blue: 1.0)
        case .longBreak: Color(red: 0.66, green: 0.43, blue: 0.98)
        }
    }

    @ViewBuilder
    private var timerPrimaryAction: some View {
        switch timerStore.state {
        case .running:
            timerStateButton("Pause", systemImage: "pause.fill") { timerStore.pause() }
        case .paused:
            timerStateButton("Resume", systemImage: "play.fill") { timerStore.resume() }
        case .finished:
            timerStateButton("Done", systemImage: "checkmark") {
                timerStore.acknowledgeFinished()
            }
        case .idle:
            EmptyView()
        }
    }

    private func timerStateButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(timerTint))
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
    }

    private func compactControlButton(
        _ symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
    }
}
