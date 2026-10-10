import SwiftUI

/// A bounded module viewport for content that can exceed the Island height.
struct IslandModuleScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.vertical) {
            content.frame(maxWidth: .infinity, alignment: .top).padding(.vertical, 1)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct IslandSelectedAccessibilityModifier: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if selected {
            content.accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}

enum IslandVisualStyle {
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.46)
    static let controlFill = Color.white.opacity(0.09)
    static let selectedFill = Color.accentColor.opacity(0.22)
    static let cardFill = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.08)
}

struct IslandPressFeedbackStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                       value: configuration.isPressed)
    }
}

struct IslandProgressTrack: View {
    let progress: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 4)
        .accessibilityValue(Text("\(Int(min(max(progress, 0), 1) * 100)) percent"))
    }
}

struct IslandModuleHeader: View {
    let title: LocalizedStringKey
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(height: 34)
    }
}

struct IslandEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.46))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 270)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}




/// A focus-independent toggle for the dark, non-activating Island panel.
/// AppKit's native switch dims its tint when the panel loses key-window focus,
/// which makes an enabled control look disabled. Keeping the visual state in
/// SwiftUI leaves the Toggle's semantics and binding intact while making the
/// enabled/disabled distinction explicit.
struct IslandClipboardToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                Capsule(style: .continuous)
                    .fill(configuration.isOn
                          ? Color.accentColor
                          : Color.white.opacity(0.16))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.96))
                            .frame(width: 26, height: 18)
                            .padding(2)
                    }
                    .frame(width: 44, height: 22)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}
