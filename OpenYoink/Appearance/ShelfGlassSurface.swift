import AppKit
import Observation
import SwiftUI

/// One corner-radius rule for every layer of the shelf glass (issue #10).
/// While the glass grows out of the edge tab it starts at the tab's own 8pt
/// radius and eases into the appearance radius as it widens, instead of jumping
/// to a half-height capsule.
enum ShelfGlassCornerRadius {
    /// Matches `EdgeTabView.cornerRadius`.
    static let edgeTabRadius: Double = 8

    static func resolved(preferred: Double, size: CGSize) -> Double {
        let shortSide = Double(min(size.width, size.height))
        guard shortSide > 0 else { return 0 }
        return min(preferred, shortSide / 2, max(edgeTabRadius, shortSide * 0.3))
    }
}

struct ShelfGlassShape: InsettableShape {
    var preferredRadius: Double
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Resolve against the full rect so an inset stroke follows the same curve.
        let radius = ShelfGlassCornerRadius.resolved(preferred: preferredRadius, size: rect.size)
        return RoundedRectangle(cornerRadius: max(0, radius - Double(insetAmount)), style: .continuous)
            .path(in: rect.insetBy(dx: insetAmount, dy: insetAmount))
    }

    func inset(by amount: CGFloat) -> ShelfGlassShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// A decorative backdrop: the shelf's content and drag/drop geometry remain native
/// and untransformed. Clear glass uses an unblurred transparent pane; liquid glass
/// and frosted materials use macOS effects. Native glass owns its reflections;
/// custom edge highlights are reserved for fallback materials.
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
    /// 空白处的点击（清选择/收起 Stack）。命中层独立于高度弹簧动画，
    /// 见下方 `stableSurfaceBounds`。
    var onBackgroundTap: (() -> Void)?
    private let content: Content
    @State private var pointer = ShelfGlassPointer()
    /// issue #10：拉环 ↔ 面板形变（nil 时始终展开）。
    @Environment(\.shelfRevealState) private var reveal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(appearance: ShelfAppearance,
         onBackgroundTap: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.appearance = appearance
        self.onBackgroundTap = onBackgroundTap
        self.content = content()
    }

    private var tracksPointer: Bool {
        appearance.shouldTrackPointer(isClassicShelf: true,
                                      reduceMotion: reduceMotion,
                                      reduceTransparency: reduceTransparency)
    }

    var body: some View {
        GeometryReader { geometry in
            let canvas = CGRect(origin: .zero, size: geometry.size)
            // The surface can be shorter than the window while its height animates.
            let bounds = reveal?.surfaceBounds(in: canvas) ?? canvas
            let glassRect = reveal?.glassRect(in: bounds) ?? bounds
            let contentVisible = reveal?.isContentVisible ?? true
            ZStack(alignment: .topLeading) {
                // A file drag can open the shelf. Keep the whole surface a drop
                // target while the glass is still growing out of the tab.
                if reveal?.capturesWholeSurface == true {
                    Color.black.opacity(0.01)
                        .frame(width: bounds.width, height: bounds.height)
                }
                // The glass morphs by resizing (never by scaling) so the system
                // material keeps sampling the real backdrop and its own edge optics.
                ZStack {
                    ShelfGlassBackdrop(appearance: appearance)
                    // Keep this coverage hit-testable and above the passthrough
                    // material. WindowServer must retain a target over empty pixels
                    // before DragContainerView can receive the file drag.
                    ShelfGlassShape(preferredRadius: appearance.cornerRadius)
                        .fill(Color.black.opacity(0.01))
                }
                    .overlay { ShelfTrackedGlassHighlights(appearance: appearance, pointer: pointer) }
                    .frame(width: max(glassRect.width, 1), height: max(glassRect.height, 1))
                    .offset(x: glassRect.minX, y: glassRect.minY)
                // Empty-surface taps live on a layer that ignores the height
                // spring. While the surface animates (selection inserts the
                // quick-action row), a moving hit target swallows the click that
                // should clear the selection, so this layer uses the static
                // target height instead of `surfaceHeight`.
                if let onBackgroundTap {
                    let hitRect = reveal?.stableSurfaceBounds(in: canvas) ?? bounds
                    Color.clear
                        .frame(width: max(hitRect.width, 1),
                               height: max(hitRect.height, 1))
                        .contentShape(ShelfGlassShape(preferredRadius: appearance.cornerRadius))
                        .offset(x: hitRect.minX, y: hitRect.minY)
                        .onTapGesture(perform: onBackgroundTap)
                }
                // Content keeps its final layout and is only *revealed* inside the
                // growing glass: it never floats outside the material, and text
                // is never scaled mid-flight.
                content
                    .frame(width: bounds.width, height: bounds.height)
                    .mask(alignment: .topLeading) {
                        ShelfGlassShape(preferredRadius: appearance.cornerRadius)
                            .frame(width: max(glassRect.width, 1), height: max(glassRect.height, 1))
                            .offset(x: glassRect.minX, y: glassRect.minY)
                    }
                    .opacity(contentVisible ? 1 : 0)
                    .allowsHitTesting(contentVisible)
            }
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
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

    private var shape: ShelfGlassShape {
        ShelfGlassShape(preferredRadius: appearance.cornerRadius)
    }

    private var materialOpacity: Double {
        appearance.surfaceOpacity(reduceTransparency: reduceTransparency)
    }

    var body: some View {
        Group {
            if appearance.usesNativeGlass(reduceTransparency: reduceTransparency) {
                material
            } else {
                ZStack {
                    material
                    shape.fill(appearance.tint.color.opacity(
                        appearance.tintOpacity(reduceTransparency: reduceTransparency)
                    ))
                }
            }
        }
        // issue #10: native glass draws its own halo/shadow outside its shape.
        // The shelf window only has an 8pt transparent margin, so that halo was
        // cut off at the window's square bounds, and the window shadow (computed
        // from those faint pixels) then outlined a rectangle around the panel.
        // Clipping to the shape keeps every pixel inside the rounded surface, so
        // the window shadow follows the rounded corners instead.
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
                                     opacity: materialOpacity,
                                     tint: appearance.nativeGlassTint)
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

    private var shape: ShelfGlassShape {
        ShelfGlassShape(preferredRadius: appearance.cornerRadius)
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
        if appearance.usesNativeGlass(reduceTransparency: reduceTransparency) {
            // issue #10: native glass keeps its own edge optics; the only
            // addition is a faint light that follows the pointer, so the panel
            // responds to the cursor without the glass itself moving or scaling.
            nativePointerGlow
                .clipShape(shape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            edgeHighlights
                .opacity(reduceTransparency ? 1 : appearance.backgroundOpacity)
                .clipShape(shape)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var nativePointerGlow: some View {
        shape
            .fill(RadialGradient(colors: [.white.opacity(appearance.highlightStrength * 0.16), .clear],
                                 center: UnitPoint(x: pointer.x, y: pointer.y),
                                 startRadius: 0, endRadius: 150))
            .blendMode(.plusLighter)
            .opacity(hoverPoint == nil ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: pointer)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: hoverPoint == nil)
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
    let tint: NSColor?

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
        view.preferredCornerRadius = cornerRadius
        if view.alphaValue != opacity { view.alphaValue = opacity }
        if view.tintColor != tint { view.tintColor = tint }
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
        // issue #10: interactive glass is meant for controls. On a whole panel a
        // press inflates the glass beyond its frame while the content stays put,
        // and the window clips the inflated edge into a stray outline.
        if #available(macOS 27.0, *), view.effectIsInteractive {
            view.effectIsInteractive = false
        }
    }
}

@available(macOS 26.0, *)
private final class ShelfPassthroughGlassView: NSGlassEffectView {
    /// The appearance radius, clamped to the current size so the glass reads as
    /// a capsule while it grows out of the narrow edge tab.
    var preferredCornerRadius: Double = 0 {
        didSet { if oldValue != preferredCornerRadius { applyCornerRadius() } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyCornerRadius()
    }

    private func applyCornerRadius() {
        let radius = ShelfGlassCornerRadius.resolved(preferred: preferredCornerRadius, size: bounds.size)
        if cornerRadius != radius { cornerRadius = radius }
    }
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
        view.preferredCornerRadius = CGFloat(cornerRadius)
    }
}

private final class ShelfPassthroughMaterialView: NSVisualEffectView {
    var preferredCornerRadius: CGFloat = 0 {
        didSet { if oldValue != preferredCornerRadius { applyCornerRadius() } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyCornerRadius()
    }

    private func applyCornerRadius() {
        let radius = CGFloat(ShelfGlassCornerRadius.resolved(preferred: Double(preferredCornerRadius),
                                                             size: bounds.size))
        if let layer, layer.cornerRadius != radius { layer.cornerRadius = radius }
    }
}
