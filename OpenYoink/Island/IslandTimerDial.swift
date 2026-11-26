import SwiftUI

struct IslandTimerDial: View {
    let timeText: String
    let stateText: String
    let systemImage: String
    let remainingFraction: Double
    let tint: Color
    let tick: Int
    let isRunning: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let fraction = min(max(remainingFraction, 0), 1)
            let radius = diameter / 2 - 9
            let radians = (fraction * 360 - 90) * Double.pi / 180

            ZStack {
                Circle()
                    .stroke(tint.opacity(isRunning ? 0.12 : 0.07), lineWidth: 1)
                    .scaleEffect(1.075)
                    .shadow(color: tint.opacity(isRunning ? 0.22 : 0.08), radius: 9)
                Circle()
                    .fill(RadialGradient(
                        colors: [tint.opacity(isRunning ? 0.18 : 0.10),
                                 Color.black.opacity(0.02)],
                        center: .center,
                        startRadius: 2,
                        endRadius: diameter * 0.54
                    ))
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.46), tint, tint.opacity(0.72)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(isRunning ? 0.52 : 0.28),
                            radius: isRunning ? 7 : 4)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.38),
                               value: fraction)

                if isRunning {
                    Circle()
                        .trim(from: 0.02, to: 0.16)
                        .stroke(
                            AngularGradient(
                                colors: [.clear, tint.opacity(0.22), .white, .clear],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(reduceMotion
                                                 ? -48
                                                 : Double(tick % 120) * 9 - 90))
                        .scaleEffect(1.075)
                        .shadow(color: tint.opacity(0.55), radius: 5)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.72),
                                   value: tick)
                }

                if fraction > 0.001 && fraction < 0.999 {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .shadow(color: tint, radius: 5)
                        .offset(x: cos(radians) * radius,
                                y: sin(radians) * radius)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.38),
                                   value: fraction)
                }

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: systemImage)
                        Text(stateText.uppercased())
                    }
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)

                    Text(timeText)
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandVisualStyle.primaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22),
                                   value: timeText)
                }
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(isRunning && !reduceMotion && tick.isMultiple(of: 2) ? 1.009 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: tick)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(stateText), \(timeText)"))
    }
}
