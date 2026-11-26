import Foundation

/// Shared grid geometry: top-level card frames in window content coordinates
/// (SwiftUI `.global`, top-left origin), scroll offset included. Grid cells

@MainActor
@Observable
final class ShelfGridGeometry {
    /// By top-level item ID. Stack children aren't reported.
    var cardFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var frameOwners: [UUID: UUID] = [:]

    func report(_ frame: CGRect, for itemID: UUID, owner: UUID) {
        frameOwners[itemID] = owner
        cardFrames[itemID] = frame
    }

    func removeFrame(for itemID: UUID, owner: UUID) {
        guard frameOwners[itemID] == owner else { return }
        frameOwners.removeValue(forKey: itemID)
        cardFrames.removeValue(forKey: itemID)
    }
}

enum DropInsertionLocator {
    /// Half the 12 pt grid spacing: how far a row's territory reaches into the gaps.
    nonisolated static let rowGapSlack: CGFloat = 6

    ///
    /// `activation` decides which line inside a card the dragged point has to
    /// cross before the slot moves in front of it:
    /// - `.center` follows the card's horizontal middle. Vertical drags and
    ///   external imports use it, so the slot follows the column under the
    ///   pointer instead of the horizontal edge the card came from.
    /// - `.leading` / `.trailing` measure `activationRatio` inward from that
    ///   edge. Horizontal Shelf reordering uses them so both directions swap
    ///   as soon as the dragged card barely enters the next one.
    nonisolated enum Activation: Sendable {
        case center
        case leading
        case trailing
    }

    nonisolated static func insertionIndex(for point: CGPoint,
                                           frames: [(index: Int, frame: CGRect)],
                                           itemCount: Int,
                                           activation: Activation = .center,
                                           activationRatio: CGFloat = 0.10) -> Int {
        guard itemCount > 0 else { return 0 }
        let ratio = min(max(activationRatio, 0), 1)
        let sorted = frames.sorted { $0.index < $1.index }
        guard !sorted.isEmpty else { return itemCount }

        // title wraps, so minY would split one visual row into overlapping
        // pseudo-rows.
        var rows: [[(index: Int, frame: CGRect)]] = []
        for entry in sorted {
            if let rowMidY = rows.last?.first?.frame.midY,
               abs(entry.frame.midY - rowMidY) <= 4 {
                rows[rows.count - 1].append(entry)
            } else {
                rows.append([entry])
            }
        }

        for row in rows {
            let rowTop = (row.map(\.frame.minY).min() ?? 0) - rowGapSlack
            let rowBottom = (row.map(\.frame.maxY).max() ?? 0) + rowGapSlack
            guard point.y >= rowTop, point.y <= rowBottom else { continue }
            for entry in row {
                let activationX: CGFloat
                switch activation {
                case .center:
                    activationX = entry.frame.midX
                case .leading:
                    activationX = entry.frame.minX + entry.frame.width * ratio
                case .trailing:
                    activationX = entry.frame.maxX - entry.frame.width * ratio
                }
                guard point.x < activationX else { continue }
                return entry.index
            }
            let lastIndex = row.map(\.index).max() ?? (itemCount - 1)
            return min(lastIndex + 1, itemCount)
        }
        return itemCount
    }
}
