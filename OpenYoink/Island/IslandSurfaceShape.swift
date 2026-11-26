import AppKit
import SwiftUI

/// Screen-attached surfaces use shallow inward top corners and fuller convex
/// bottom corners. The shape stays flush with the screen edge while avoiding
/// the square, pasted-on silhouette of a regular rounded rectangle.
struct IslandSurfaceShape: InsettableShape {
    var attachedToScreenTop: Bool
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> IslandSurfaceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard attachedToScreenTop else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)
        }

        let bottomRadius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topCut = min(7, max(4, bottomRadius * 0.45))
        let leftBody = rect.minX + topCut
        let rightBody = rect.maxX - topCut
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: leftBody, y: rect.minY + topCut),
            control1: CGPoint(x: rect.minX + topCut * 0.55, y: rect.minY),
            control2: CGPoint(x: leftBody, y: rect.minY + topCut * 0.45)
        )
        path.addLine(to: CGPoint(x: leftBody, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftBody + bottomRadius, y: rect.maxY),
            control: CGPoint(x: leftBody, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBody - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rightBody, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rightBody, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBody, y: rect.minY + topCut))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rightBody, y: rect.minY + topCut * 0.45),
            control2: CGPoint(x: rect.maxX - topCut * 0.55, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
