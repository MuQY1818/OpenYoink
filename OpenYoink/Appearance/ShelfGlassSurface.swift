import AppKit
import SwiftUI

/// A decorative backdrop: the shelf's content and drag/drop geometry remain native
/// and untransformed. The optical material is supplied by macOS; the moving edge
/// highlights are inspired by liquid-glass-react, not a desktop sampling shader.
struct ShelfGlassSurface: View {
    let appearance: ShelfAppearance
    var hoverPoint: CGPoint? = nil
    var blendsWithinWindow = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var effectiveScheme: ColorScheme {
        appearance.theme.colorScheme ?? colorScheme
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
    }

    private var backdropOpacity: Double {
        reduceTransparency ? 1 : appearance.backgroundOpacity
    }

    /// Normalize even externally supplied coordinates, so decoration cannot pull
    /// the shelf's edge away from its stable material or interfere with hit tests.
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
        ZStack {
            material
            // Keep a stable tint layer across all native material implementations.
            shape.fill(appearance.tint.color.opacity(appearance.tintStrength * backdropOpacity))
            edgeHighlights.opacity(backdropOpacity)
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
                       : Color(white: 0.95)).opacity(backdropOpacity)
        } else if #available(macOS 26.0, *),
                  appearance.material == .regular || appearance.material == .clear {
            ShelfNativeGlassBackdrop(clear: appearance.material == .clear,
                                     cornerRadius: appearance.cornerRadius,
                                     colorScheme: effectiveScheme,
                                     opacity: backdropOpacity)
        } else {
            ShelfMaterialBackdrop(material: fallbackMaterial,
                                  cornerRadius: appearance.cornerRadius,
                                  colorScheme: effectiveScheme,
                                  blendsWithinWindow: blendsWithinWindow,
                                  opacity: backdropOpacity)
        }
    }

    private var fallbackMaterial: NSVisualEffectView.Material {
        switch appearance.material {
        case .clear: .underWindowBackground
        case .frosted: .popover
        case .regular, .solid: .hudWindow
        }
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
                shape.fill(
                    RadialGradient(colors: [.white.opacity(strength * 0.10), .clear],
                                   center: UnitPoint(x: 0.5 + horizontal * 0.5,
                                                     y: 0.5 + vertical * 0.5),
                                   startRadius: 0, endRadius: 160))
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
    let clear: Bool
    let cornerRadius: Double
    let colorScheme: ColorScheme
    let opacity: Double

    func makeNSView(context: Context) -> ShelfPassthroughGlassView {
        let view = ShelfPassthroughGlassView()
        view.contentView = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShelfPassthroughGlassView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: ShelfPassthroughGlassView) {
        view.style = clear ? .clear : .regular
        view.cornerRadius = cornerRadius
        view.alphaValue = opacity
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
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
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShelfPassthroughMaterialView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: ShelfPassthroughMaterialView) {
        view.material = material
        view.blendingMode = blendsWithinWindow ? .withinWindow : .behindWindow
        view.alphaValue = opacity
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
    }
}

private final class ShelfPassthroughMaterialView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
