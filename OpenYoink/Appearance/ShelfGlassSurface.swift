import AppKit
import Observation
import SwiftUI

/// A decorative backdrop: the shelf's content and drag/drop geometry remain native
/// and untransformed. Clear glass uses an unblurred transparent pane; liquid glass
/// and frosted materials use macOS effects. Moving edge highlights are inspired
/// by liquid-glass-react, without sampling the desktop in the application.
struct ShelfGlassSurface: View {
    let appearance: ShelfAppearance
    var hoverPoint: CGPoint? = nil
    var blendsWithinWindow = false

    var body: some View {
        ShelfGlassBackdrop(appearance: appearance, blendsWithinWindow: blendsWithinWindow)
            .overlay { ShelfGlassHighlights(appearance: appearance, hoverPoint: hoverPoint) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Only the highlight reader observes the pointer. Hover events do not invalidate
/// the shelf content, the tracking container, or the native glass backdrop.
struct ShelfInteractiveGlassSurface<Content: View>: View {
    let appearance: ShelfAppearance
    private let content: Content
    @State private var pointer = ShelfGlassPointer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(appearance: ShelfAppearance, @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.content = content()
    }

    private var tracksPointer: Bool {
        appearance.shouldTrackPointer(isClassicShelf: true,
                                      reduceMotion: reduceMotion,
                                      reduceTransparency: reduceTransparency)
    }

    var body: some View {
        GeometryReader { geometry in
            ShelfGlassBackdrop(appearance: appearance)
                .overlay { ShelfTrackedGlassHighlights(appearance: appearance, pointer: pointer) }
                .overlay { content }
                .onContinuousHover { phase in
                    guard tracksPointer else { return }
                    switch phase {
                    case let .active(location):
                        pointer.update(CGPoint(
                            x: min(1, max(0, location.x / max(geometry.size.width, 1))),
                            y: min(1, max(0, location.y / max(geometry.size.height, 1)))
                        ))
                    case .ended:
                        pointer.update(nil)
                    }
                }
        }
        .onChange(of: tracksPointer) { _, enabled in
            if !enabled { pointer.update(nil) }
        }
        .onDisappear { pointer.update(nil) }
    }
}

@Observable
@MainActor
private final class ShelfGlassPointer {
    private(set) var point: CGPoint?

    func update(_ point: CGPoint?) {
        if self.point != point { self.point = point }
    }
}

private struct ShelfTrackedGlassHighlights: View {
    let appearance: ShelfAppearance
    let pointer: ShelfGlassPointer

    var body: some View {
        ShelfGlassHighlights(appearance: appearance, hoverPoint: pointer.point)
    }
}

private struct ShelfGlassBackdrop: View {
    let appearance: ShelfAppearance
    var blendsWithinWindow = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var effectiveScheme: ColorScheme {
        appearance.theme.colorScheme ?? colorScheme
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
    }

    private var materialOpacity: Double {
        appearance.surfaceOpacity(reduceTransparency: reduceTransparency)
    }

    var body: some View {
        ZStack {
            material
            shape.fill(appearance.tint.color.opacity(
                appearance.tintOpacity(reduceTransparency: reduceTransparency)
            ))
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var material: some View {
        if reduceTransparency || appearance.material == .solid {
            shape.fill(effectiveScheme == .dark
                       ? Color(white: 0.10)
                       : Color(white: 0.95)).opacity(materialOpacity)
        } else if appearance.material == .clear {
            // A native clear glass effect still refracts and blurs the backdrop.
            // Use only a faint base and the shared edge reflections here.
            shape.fill(effectiveScheme == .dark ? Color.black : Color.white)
                .opacity(materialOpacity)
        } else if #available(macOS 26.0, *), appearance.material == .regular {
            ShelfNativeGlassBackdrop(cornerRadius: appearance.cornerRadius,
                                     colorScheme: effectiveScheme,
                                     opacity: materialOpacity)
        } else {
            ShelfMaterialBackdrop(material: fallbackMaterial,
                                  cornerRadius: appearance.cornerRadius,
                                  colorScheme: effectiveScheme,
                                  blendsWithinWindow: blendsWithinWindow,
                                  opacity: materialOpacity)
        }
    }

    private var fallbackMaterial: NSVisualEffectView.Material {
        switch appearance.material {
        case .clear: .underWindowBackground
        case .frosted: .popover
        case .regular, .solid: .hudWindow
        }
    }
}

private struct ShelfGlassHighlights: View {
    let appearance: ShelfAppearance
    var hoverPoint: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
    }

    private var pointer: CGPoint {
        guard appearance.shouldTrackPointer(isClassicShelf: true,
                                            reduceMotion: reduceMotion,
                                            reduceTransparency: reduceTransparency),
              let hoverPoint else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(x: min(max(hoverPoint.x, 0), 1),
                       y: min(max(hoverPoint.y, 0), 1))
    }

    var body: some View {
        edgeHighlights
            .opacity(reduceTransparency ? 1 : appearance.backgroundOpacity)
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var edgeHighlights: some View {
        let movement = reduceMotion ? 0 : min(max(appearance.elasticity / 0.35, 0), 1)
        let horizontal = (pointer.x - 0.5) * 2 * movement
        let vertical = (pointer.y - 0.5) * 2 * movement
        let strength = appearance.highlightStrength
        let angle = (135 + horizontal * 110 + vertical * 35) * Double.pi / 180
        let start = UnitPoint(x: 0.5 - cos(angle) * 0.5,
                              y: 0.5 - sin(angle) * 0.5)
        let end = UnitPoint(x: 0.5 + cos(angle) * 0.5,
                            y: 0.5 + sin(angle) * 0.5)

        return ZStack {
            // The fine contour stays anchored while the broader reflected light
            // moves inside it. The native glass beneath never moves or scales.
            shape.strokeBorder(Color.white.opacity(strength * 0.22), lineWidth: 0.5)
            ZStack {
                shape.strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: 0),
                        .init(color: .white.opacity(strength * 0.28), location: 0.30),
                        .init(color: .white.opacity(strength * 0.85), location: 0.64),
                        .init(color: .white.opacity(0), location: 1)
                    ], startPoint: start, endPoint: end), lineWidth: 1.5)
                    .blendMode(.screen)
                shape.strokeBorder(
                    LinearGradient(colors: [
                        .white.opacity(strength * 0.55),
                        .clear,
                        .black.opacity(strength * 0.20)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .blendMode(.overlay)
                if appearance.material != .clear {
                    shape.fill(
                        RadialGradient(colors: [.white.opacity(strength * 0.10), .clear],
                                       center: UnitPoint(x: 0.5 + horizontal * 0.5,
                                                         y: 0.5 + vertical * 0.5),
                                       startRadius: 0, endRadius: 160))
                }
                shape.strokeBorder(
                    RadialGradient(colors: [.white.opacity(strength * 0.95), .clear],
                                   center: UnitPoint(x: 0.5 + horizontal * 0.5,
                                                     y: 0.5 + vertical * 0.5),
                                   startRadius: 0, endRadius: 90), lineWidth: 3)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: pointer)
    }
}

@available(macOS 26.0, *)
private struct ShelfNativeGlassBackdrop: NSViewRepresentable {
    let cornerRadius: Double
    let colorScheme: ColorScheme
    let opacity: Double

    func makeNSView(context: Context) -> ShelfPassthroughGlassView {
        let view = ShelfPassthroughGlassView()
        view.contentView = NSView()
        view.style = .regular
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShelfPassthroughGlassView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: ShelfPassthroughGlassView) {
        if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
        if view.alphaValue != opacity { view.alphaValue = opacity }
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
}

@available(macOS 26.0, *)
private final class ShelfPassthroughGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ShelfMaterialBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let cornerRadius: Double
    let colorScheme: ColorScheme
    let blendsWithinWindow: Bool
    let opacity: Double

    func makeNSView(context: Context) -> ShelfPassthroughMaterialView {
        let view = ShelfPassthroughMaterialView()
        view.wantsLayer = true
        view.state = .active
        view.layer?.masksToBounds = true
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShelfPassthroughMaterialView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: ShelfPassthroughMaterialView) {
        if view.material != material { view.material = material }
        let blendingMode: NSVisualEffectView.BlendingMode = blendsWithinWindow
            ? .withinWindow : .behindWindow
        if view.blendingMode != blendingMode { view.blendingMode = blendingMode }
        if view.alphaValue != opacity { view.alphaValue = opacity }
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
        if let layer = view.layer, layer.cornerRadius != CGFloat(cornerRadius) {
            layer.cornerRadius = CGFloat(cornerRadius)
        }
    }
}

private final class ShelfPassthroughMaterialView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
