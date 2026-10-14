import AppKit
import SwiftUI

/// One versioned preferences value; resetting it never changes shelf data or triggers.
struct ShelfAppearance: Codable, Equatable, Sendable {
    enum Material: String, Codable, CaseIterable, Identifiable, Sendable {
        case regular, clear, frosted, solid
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .regular: "Liquid Glass"
            case .clear: "Clear Glass"
            case .frosted: "Frosted"
            case .solid: "Solid"
            }
        }
    }

    enum Theme: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum Tint: String, Codable, CaseIterable, Identifiable, Sendable {
        case neutral, blue, purple, pink, mint, amber
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .neutral: "Neutral"
            case .blue: "Blue"
            case .purple: "Purple"
            case .pink: "Pink"
            case .mint: "Mint"
            case .amber: "Amber"
            }
        }
        var color: Color { Color(nsColor: nsColor) }
        var nsColor: NSColor {
            switch self {
            case .neutral: .white
            case .blue: NSColor(srgbRed: 0.24, green: 0.52, blue: 1, alpha: 1)
            case .purple: NSColor(srgbRed: 0.62, green: 0.40, blue: 0.96, alpha: 1)
            case .pink: NSColor(srgbRed: 0.96, green: 0.38, blue: 0.60, alpha: 1)
            case .mint: NSColor(srgbRed: 0.24, green: 0.78, blue: 0.65, alpha: 1)
            case .amber: NSColor(srgbRed: 0.98, green: 0.68, blue: 0.25, alpha: 1)
            }
        }
    }

    var material: Material = .regular
    var theme: Theme = .system
    var tint: Tint = .neutral
    var backgroundOpacity: Double = 1
    var tintStrength: Double = 0.10
    var cornerRadius: Double = 24
    var highlightStrength: Double = 0.50
    var elasticity: Double = 0.12
    var followsPointer = true
    var cardOpacity: Double = 0.16
    var cardCornerRadius: Double = 12

    static let `default` = ShelfAppearance()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case material, theme, tint, backgroundOpacity, tintStrength, cornerRadius
        case highlightStrength, elasticity, followsPointer, cardOpacity, cardCornerRadius
    }

    /// Missing new fields keep old customizations instead of resetting the profile.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        material = try values.decodeIfPresent(Material.self, forKey: .material) ?? .regular
        theme = try values.decodeIfPresent(Theme.self, forKey: .theme) ?? .system
        tint = try values.decodeIfPresent(Tint.self, forKey: .tint) ?? .neutral
        backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1
        tintStrength = try values.decodeIfPresent(Double.self, forKey: .tintStrength) ?? 0.10
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 24
        highlightStrength = try values.decodeIfPresent(Double.self, forKey: .highlightStrength) ?? 0.50
        elasticity = try values.decodeIfPresent(Double.self, forKey: .elasticity) ?? 0.12
        followsPointer = try values.decodeIfPresent(Bool.self, forKey: .followsPointer) ?? true
        cardOpacity = try values.decodeIfPresent(Double.self, forKey: .cardOpacity) ?? 0.16
        cardCornerRadius = try values.decodeIfPresent(Double.self, forKey: .cardCornerRadius) ?? 12
    }

    /// Corrupt or hand-edited preferences must not produce invalid view geometry.
    func normalized() -> Self {
        var result = self
        func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        result.backgroundOpacity = bounded(backgroundOpacity, 0...1, fallback: Self.default.backgroundOpacity)
        result.tintStrength = bounded(tintStrength, 0...0.6, fallback: Self.default.tintStrength)
        result.cornerRadius = bounded(cornerRadius, 8...40, fallback: Self.default.cornerRadius)
        result.highlightStrength = bounded(highlightStrength, 0...1, fallback: Self.default.highlightStrength)
        result.elasticity = bounded(elasticity, 0...0.35, fallback: Self.default.elasticity)
        result.cardOpacity = bounded(cardOpacity, 0...1, fallback: Self.default.cardOpacity)
        result.cardCornerRadius = bounded(cardCornerRadius, 4...20, fallback: Self.default.cardCornerRadius)
        return result
    }
}
