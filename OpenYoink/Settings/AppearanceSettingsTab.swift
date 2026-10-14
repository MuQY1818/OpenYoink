import SwiftUI

struct AppearanceSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motionPreviewTrigger = 0

    private var canPreviewMotion: Bool {
        settings.appearance.shouldTrackPointer(isClassicShelf: true,
                                              reduceMotion: reduceMotion,
                                              reduceTransparency: reduceTransparency)
    }

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Live Preview").font(.headline)
                    Spacer()
                    Button("Preview Motion") { motionPreviewTrigger += 1 }
                        .disabled(!canPreviewMotion)
                        .accessibilityIdentifier("appearance.previewMotion")
                }
                PhaseAnimator(MotionPreviewPhase.allCases, trigger: motionPreviewTrigger) { phase in
                    ShelfAppearancePreview(demoPointer: phase.point)
                } animation: { _ in .easeInOut(duration: 0.4) }
                .frame(height: 150)
                .accessibilityIdentifier("appearance.preview")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            controls
        }
        .accessibilityIdentifier("settings.appearance")
    }

    private var controls: some View {
        @Bindable var settings = settings
        return Form {
            Section("Material and Theme") {
                Picker("Glass Material", selection: $settings.appearance.material) {
                    ForEach(ShelfAppearance.Material.allCases) { material in
                        Text(material.title).tag(material)
                    }
                }
                .accessibilityIdentifier("appearance.material")

                appearanceSlider("Background Transparency", value: Binding(
                    get: { 1 - settings.appearance.backgroundOpacity },
                    set: { settings.appearance.backgroundOpacity = 1 - $0 }
                ),
                                 range: 0...1, unit: .percent, id: "backgroundOpacity")
                    .disabled(reduceTransparency)
                Text(reduceTransparency
                     ? "Background transparency is controlled by Reduce Transparency in system settings."
                     : "100% clears the glass background. Files and text stay fully visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Color Theme", selection: $settings.appearance.theme) {
                    ForEach(ShelfAppearance.Theme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance.theme")
            }

            Section("Tint") {
                Picker("Tint Color", selection: $settings.appearance.tint) {
                    ForEach(ShelfAppearance.Tint.allCases) { tint in
                        Label {
                            Text(tint.title)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(tint.color)
                        }
                        .tag(tint)
                    }
                }
                .accessibilityIdentifier("appearance.tint")

                appearanceSlider("Tint Intensity", value: $settings.appearance.tintStrength,
                                 range: 0...0.6, unit: .percent, id: "tintStrength")
            }

            Section("Corners and File Cards") {
                appearanceSlider("Shelf Corner Radius", value: $settings.appearance.cornerRadius,
                                 range: 8...40, unit: .points, id: "cornerRadius")
                appearanceSlider("File Card Opacity", value: $settings.appearance.cardOpacity,
                                 range: 0...1, unit: .percent, id: "cardOpacity")
                appearanceSlider("File Card Corner Radius", value: $settings.appearance.cardCornerRadius,
                                 range: 4...20, unit: .points, id: "cardCornerRadius")
                Text("File card controls apply to files on the shelf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Highlights and Motion") {
                appearanceSlider("Extra Edge Highlight", value: $settings.appearance.highlightStrength,
                                 range: 0...1, unit: .percent, id: "highlightStrength")
                appearanceSlider("Highlight Movement", value: Binding(
                    get: { settings.appearance.elasticity / 0.35 },
                    set: { settings.appearance.elasticity = $0 * 0.35 }
                ), range: 0...1, unit: .percent, id: "elasticity", continuous: true)
                    .disabled(!settings.appearance.followsPointer
                              || settings.appearance.highlightStrength == 0 || reduceMotion)
                Toggle("Highlights Follow Pointer", isOn: $settings.appearance.followsPointer)
                    .accessibilityIdentifier("appearance.followsPointer")
                    .disabled(settings.appearance.highlightStrength == 0 || reduceMotion)
                Text("Raise Extra Edge Highlight above 0%, then move the pointer over the preview or shelf to see the motion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Restore Appearance Defaults") {
                    settings.resetAppearance()
                }
                .accessibilityIdentifier("appearance.restoreDefaults")
            }
        }
        .formStyle(.grouped)
    }

    private enum MotionPreviewPhase: CaseIterable {
        case idle, left, top, right, bottom
        var point: CGPoint? {
            switch self {
            case .idle: nil
            case .left: CGPoint(x: 0, y: 0.5)
            case .top: CGPoint(x: 0.5, y: 0)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottom: CGPoint(x: 0.5, y: 1)
            }
        }
    }

    private enum SliderUnit {
        case percent
        case points
    }

    private func appearanceSlider(_ title: LocalizedStringKey, value: Binding<Double>,
                                  range: ClosedRange<Double>, unit: SliderUnit,
                                  id: String, continuous: Bool = false) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Group {
                    if continuous {
                        Slider(value: value, in: range)
                    } else {
                        Slider(value: value, in: range, step: unit == .points ? 1 : 0.01)
                    }
                }
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("appearance.\(id)")
                Group {
                    if unit == .points {
                        Text("\(Int(value.wrappedValue)) pt")
                    } else {
                        Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    }
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct ShelfAppearancePreview: View {
    @Environment(SettingsStore.self) private var settings
    var demoPointer: CGPoint? = nil
    private var appearance: ShelfAppearance { settings.appearance }
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hoverPoint: CGPoint?

    private var shouldTrackPointer: Bool {
        appearance.shouldTrackPointer(isClassicShelf: true,
                                      reduceMotion: reduceMotion,
                                      reduceTransparency: reduceTransparency)
    }

    var body: some View {
        let appearance = settings.appearance
        return GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.65), .cyan.opacity(0.4), .pink.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(.orange.opacity(0.75))
                    .frame(width: 118, height: 118)
                    .offset(x: -geometry.size.width * 0.25, y: 45)
                RoundedRectangle(cornerRadius: 28)
                    .fill(.purple.opacity(0.65))
                    .frame(width: 110, height: 160)
                    .rotationEffect(.degrees(28))
                    .offset(x: geometry.size.width * 0.25, y: -28)

                previewShelf
                    .frame(width: max(0, min(330, geometry.size.width - 36)))
                    .environment(\.colorScheme, appearance.theme.colorScheme ?? systemColorScheme)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var previewShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Side Shelf", systemImage: "tray.fill")
                    .font(.headline)
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                previewCard("Document", symbol: "doc.text.fill", color: .blue)
                previewCard("Image", symbol: "photo.fill", color: .pink)
                previewCard("Folder", symbol: "folder.fill", color: .mint)
            }
        }
        .padding(16)
        .background {
            ShelfGlassSurface(appearance: appearance,
                              hoverPoint: shouldTrackPointer ? (demoPointer ?? hoverPoint) : nil,
                              blendsWithinWindow: true)
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard shouldTrackPointer else { return }
                        switch phase {
                        case .active(let location):
                            let point = CGPoint(
                                x: min(1, max(0, location.x / max(1, geometry.size.width))),
                                y: min(1, max(0, location.y / max(1, geometry.size.height)))
                            )
                            if hoverPoint != point { hoverPoint = point }
                        case .ended:
                            if hoverPoint != nil { hoverPoint = nil }
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous))
        .onChange(of: shouldTrackPointer) { _, enabled in
            if !enabled, hoverPoint != nil { hoverPoint = nil }
        }
        .onDisappear { hoverPoint = nil }
        .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
    }

    private func previewCard(_ title: LocalizedStringKey, symbol: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: appearance.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)
                    .opacity(reduceTransparency ? 1 : appearance.cardOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: appearance.cardCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}
