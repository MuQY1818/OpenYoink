import Foundation

/// Pure side-shelf layout: target screen, edge-attached frames, the hide
/// direction, clamping, and validation of a custom frame. Screens arrive as
/// plain `ScreenGeometry` values, so everything is testable.
///
/// Global screen coordinates (the space of `NSEvent.mouseLocation` and
/// `NSScreen.frame`, origin at the main screen's bottom left).
enum ShelfLayoutEngine {
    struct ScreenGeometry: Equatable, Sendable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    /// Only if there is no screen at all, which a running Mac always has.
    static let fallbackSize = CGSize(width: 320, height: 600)

    /// Must match `ShelfView.columnWidth` / `.gridSpacing`, or the column count
    /// would disagree with SwiftUI's adaptive grid.
    static let gridColumnMinimum: CGFloat = 84
    static let gridSpacing: CGFloat = 12
    /// Window padding 8×2 plus content padding 8×2.
    static let contentPadding: CGFloat = 32

    static let handleContentAllowance: CGFloat = 0
    /// Title bar plus its stack spacing.
    static let headerHeight: CGFloat = 28
    /// The activity strip plus spacing; reserved only while it shows.
    static let activityStripHeight: CGFloat = 86
    /// Selection action bar (36pt) plus up to 8pt surrounding VStack spacing
    /// (the expanded-stack presentation uses the larger spacing).
    static let quickActionBarHeight: CGFloat = 44
    /// Two title lines plus one status line. Ready cards stay quiet; managed,
    /// in-progress and failed states need real words, not just a badge or color.
    static let cardRowHeight: CGFloat = 132
    /// Empty shelf: just enough for the empty-state illustration.
    static let emptyStateHeight: CGFloat = 200
    /// At most 80 % of the visible height; the grid scrolls beyond.
    static let maximumHeightFraction: CGFloat = 0.8

    /// The screen containing the point, else the first (main) one; nil without
    /// screens. Same rule as `NSScreen.containing(_:)`.
    static func targetScreen(mouseLocation: CGPoint, screens: [ScreenGeometry]) -> ScreenGeometry? {
        screens.first { $0.frame.contains(mouseLocation) } ?? screens.first
    }

    static func columnCount(forPanelWidth width: CGFloat) -> Int {
        let gridWidth = width - contentPadding - handleContentAllowance
        return gridColumnCount(for: gridWidth)
    }

    /// Column count for a grid viewport that is already inside the padding.
    ///
    /// SwiftUI's `adaptive` grid re-derives this from its own width, and the
    /// scrolling container is a little narrower than the plain grid, so the
    /// same shelf switched from three columns to two once it started
    /// scrolling. Deriving the count here keeps both states identical.
    static func gridColumnCount(for gridWidth: CGFloat) -> Int {
        max(1, Int((gridWidth + gridSpacing) / (gridColumnMinimum + gridSpacing)))
    }

    /// Use the same conservative row allowance as the window's compact layout.
    /// The viewport width is already inside the shelf's padding and handle.
    static func gridFits(itemCount: Int, viewport: CGSize) -> Bool {
        guard itemCount > 0, viewport.width >= gridColumnMinimum, viewport.height > 0 else { return false }
        let columns = max(1, Int((viewport.width + gridSpacing) / (gridColumnMinimum + gridSpacing)))
        let rows = (itemCount + columns - 1) / columns
        let height = CGFloat(rows) * cardRowHeight + CGFloat(rows - 1) * gridSpacing
        return height <= viewport.height
    }

    /// Title bar + padding + rows; at most 80 % of the visible height (the rest
    /// scrolls); an empty shelf gets the compact empty height.
    static func contentHeight(itemCount: Int,
                              panelWidth: CGFloat,
                              visibleHeight: CGFloat,
                              hasActivity: Bool = false,
                              hasQuickActions: Bool = false,
                              hasSearchControls: Bool = false) -> CGFloat {
        let cap = visibleHeight * maximumHeightFraction
        let activityHeight = (hasActivity ? activityStripHeight : 0) + (hasSearchControls ? 60 : 0)
        guard itemCount > 0 else { return min(emptyStateHeight + activityHeight, cap) }
        let quickActionHeight = hasQuickActions ? quickActionBarHeight : 0
        let columns = columnCount(forPanelWidth: panelWidth)
        let rows = max(1, (itemCount + columns - 1) / columns)
        let gridHeight = CGFloat(rows) * cardRowHeight + CGFloat(rows - 1) * gridSpacing
        return min(headerHeight + gridHeight + contentPadding + activityHeight + quickActionHeight,
                   cap)
    }

    static func edgeAttachedFrame(position: SettingsStore.ShelfPosition,
                                  width: CGFloat,
                                  height: CGFloat,
                                  visibleFrame: CGRect,
                                  edgeOffset: CGFloat = 0.5) -> CGRect? {
        let clampedOffset = min(max(edgeOffset, 0), 1)
        let travel = max(0, visibleFrame.height - height)
        let y = visibleFrame.minY + travel * clampedOffset
        switch position {
        case .left:
            return CGRect(x: visibleFrame.minX, y: y,
                          width: width, height: height)
        case .right:
            return CGRect(x: visibleFrame.maxX - width, y: y,
                          width: width, height: height)
        case .custom:
            return nil
        }
    }

    /// Shifted one panel width past the attached edge, so it slides out that
    /// way. A custom frame stays put and only fades.
    static func hiddenFrame(for frame: CGRect, position: SettingsStore.ShelfPosition) -> CGRect {
        switch position {
        case .right: return frame.offsetBy(dx: frame.width, dy: 0)
        case .left: return frame.offsetBy(dx: -frame.width, dy: 0)
        case .custom: return frame
        }
    }

    static let revealEdgeBleed: CGFloat = 12

    static func revealOriginRect(surfaceFrame: CGRect,
                                 tabFrame: CGRect,
                                 position: SettingsStore.ShelfPosition,
                                 windowInset: CGFloat) -> CGRect? {
        guard surfaceFrame.width > 0, surfaceFrame.height > 0 else { return nil }
        let height = min(tabFrame.height, surfaceFrame.height)
        let top = min(max(surfaceFrame.maxY - tabFrame.maxY, 0), surfaceFrame.height - height)
        let width = min(tabFrame.width, surfaceFrame.width) + revealEdgeBleed
        switch position {
        case .right:
            let screenEdge = surfaceFrame.width + windowInset
            return CGRect(x: screenEdge - width + revealEdgeBleed, y: top,
                          width: width, height: height)
        case .left:
            return CGRect(x: -windowInset - revealEdgeBleed, y: top,
                          width: width, height: height)
        case .custom:
            return nil
        }
    }

    /// The visible width of the resting tab.
    static let edgeTabWidth: CGFloat = 14
    /// Its length along the edge.
    static let edgeTabHeight: CGFloat = 84

    /// Keep at least 2pt around the glyph, independently of the tab's hit area.
    static func edgeTabIconFrame(in bounds: CGRect, size: Double) -> CGRect {
        let requested = SettingsStore.normalizedEdgeTabIconSize(size)
        let side = min(CGFloat(requested), max(0, min(bounds.width, bounds.height) - 4))
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                      width: side, height: side)
    }
    /// Growth while emphasized (drop hint, drop hover); edge and center y stay.
    static let edgeTabEmphasizedWidth: CGFloat = 18
    static let edgeTabEmphasizedHeight: CGFloat = 92
    /// While dragging the tab: past the screen's midline, this close to the
/// opposite edge switches sides.
    static let edgeTabFlipDistance: CGFloat = 120

    static func edgeTabFrame(position: SettingsStore.ShelfPosition,
                             offset: CGFloat,
                             visibleFrame: CGRect) -> CGRect? {
        let x: CGFloat
        switch position {
        case .left: x = visibleFrame.minX
        case .right: x = visibleFrame.maxX - edgeTabWidth
        case .custom: return nil
        }
        let height = min(edgeTabHeight, visibleFrame.height)
        let clampedOffset = min(max(offset, 0), 1)
        let travel = max(0, visibleFrame.height - height)
        let centerY = visibleFrame.minY + height / 2 + travel * clampedOffset
        return CGRect(x: x, y: centerY - height / 2,
                      width: edgeTabWidth, height: height)
    }

    /// The tab center's y while dragging → offset in [0, 1]; 0.5 when the
    /// visible height leaves no room to travel.
    static func edgeTabOffset(forCenterY centerY: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let height = min(edgeTabHeight, visibleFrame.height)
        let travel = visibleFrame.height - height
        guard travel > 0 else { return 0.5 }
        let raw = (centerY - visibleFrame.minY - height / 2) / travel
        return min(max(raw, 0), 1)
    }

    /// Slightly larger for emphasis: the edge side and center y stay, it grows
    /// inwards and symmetrically, clamped to the visible frame.
    static func edgeTabEmphasisFrame(from base: CGRect,
                                     position: SettingsStore.ShelfPosition,
                                     visibleFrame: CGRect) -> CGRect {
        let x: CGFloat
        switch position {
        case .left: x = visibleFrame.minX
        case .right: x = visibleFrame.maxX - edgeTabEmphasizedWidth
        case .custom: return base
        }
        let height = min(edgeTabEmphasizedHeight, visibleFrame.height)
        let frame = CGRect(x: x, y: base.midY - height / 2,
                           width: edgeTabEmphasizedWidth, height: height)
        return clamped(frame, into: visibleFrame)
    }

    static func shouldFlipSide(position: SettingsStore.ShelfPosition,
                               cursorLocation: CGPoint,
                               screenFrame: CGRect,
                               flipDistance: CGFloat = edgeTabFlipDistance) -> Bool {
        switch position {
        case .right:
            return cursorLocation.x < screenFrame.midX
                && cursorLocation.x - screenFrame.minX < flipDistance
        case .left:
            return cursorLocation.x > screenFrame.midX
                && screenFrame.maxX - cursorLocation.x < flipDistance
        case .custom:
            return false
        }
    }

    static let innerEdgeHandleWidth: CGFloat = 10

    /// Which edge of the panel the collapse handle sits on.
    enum InnerEdgeHandleSide: Sendable, Equatable {
        /// Left edge (right-anchored shelf); the chevron points right.
        case leading
        /// Right edge (left-anchored shelf).
        case trailing
    }

    /// Always the inner edge, facing the screen center: right anchor → leading,
    /// left anchor → trailing. nil for `.custom`, which the title-bar drag
    /// handle already covers.
    static func innerEdgeHandleSide(for position: SettingsStore.ShelfPosition) -> InnerEdgeHandleSide? {
        switch position {
        case .right: return .leading
        case .left: return .trailing
        case .custom: return nil
        }
    }

    /// Shrinks the frame to fit, then moves it the least distance into the
    /// visible frame. A frame already inside is returned unchanged.
    static func clamped(_ frame: CGRect, into visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visibleFrame.width),
                          height: min(frame.height, visibleFrame.height))
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// The screen sharing the most area with the frame. Uses the full frame, not
    /// the visible one, so a panel dragged over the menu bar or Dock still
    /// belongs to that screen. nil when it touches no screen.
    static func bestIntersectingScreen(for frame: CGRect, screens: [ScreenGeometry]) -> ScreenGeometry? {
        var best: ScreenGeometry?
        var bestArea: CGFloat = 0
        for screen in screens where screen.frame.intersects(frame) {
            let intersection = screen.frame.intersection(frame)
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    /// Width from settings (it still applies to `.custom`), height and origin
    /// from the persisted frame, clamped into the visible frame of the screen
    /// it overlaps most. nil when it is on no screen (that display is gone).
    static func validatedCustomFrame(_ persisted: CGRect,
                                     width: CGFloat,
                                     screens: [ScreenGeometry]) -> CGRect? {
        guard let screen = bestIntersectingScreen(for: persisted, screens: screens) else { return nil }
        let sized = CGRect(x: persisted.minX, y: persisted.minY, width: width, height: persisted.height)
        return clamped(sized, into: screen.visibleFrame)
    }

    /// After a Space switch: a frame still on some screen is clamped back into
    /// it (normally a no-op); nil when it is on no screen, and the caller
    /// recomputes `targetFrame`.
    ///
    /// It doesn't follow the pointer: the panel keeps its global position on
    /// every Space, so following would drift it across displays.
    static func onscreenCorrection(for frame: CGRect, screens: [ScreenGeometry]) -> CGRect? {
        guard let screen = bestIntersectingScreen(for: frame, screens: screens) else { return nil }
        return clamped(frame, into: screen.visibleFrame)
    }

    /// One decision for show, screen changes, settings changes and item changes:
    /// - left/right: attached to the edge of the pointer's screen (main screen
    ///   if that one is gone), as tall as the content (at most 80 %), placed
    ///   vertically by `edgeOffset`;
    /// - custom: the validated persisted frame (its height doesn't follow the
    ///   content); without one, or when its display is gone, it starts from the
    ///   right-edge default;
    /// - no screens at all: a frame at the origin.
    static func targetFrame(position: SettingsStore.ShelfPosition,
                            width: CGFloat,
                            itemCount: Int,
                            hasActivity: Bool = false,
                            hasQuickActions: Bool = false,
                            hasSearchControls: Bool = false,
                            mouseLocation: CGPoint,
                            screens: [ScreenGeometry],
                            persistedCustomFrame: CGRect?,
                            edgeOffset: CGFloat = 0.5) -> CGRect {
        guard let screen = targetScreen(mouseLocation: mouseLocation, screens: screens) else {
            return CGRect(origin: .zero, size: fallbackSize)
        }
        switch position {
        case .left, .right:
            let height = contentHeight(itemCount: itemCount,
                                       panelWidth: width,
                                       visibleHeight: screen.visibleFrame.height,
                                       hasActivity: hasActivity,
                                       hasQuickActions: hasQuickActions,
                                       hasSearchControls: hasSearchControls)
            // left/right always produce an edge frame; only .custom returns nil.
            return edgeAttachedFrame(position: position, width: width, height: height,
                                     visibleFrame: screen.visibleFrame, edgeOffset: edgeOffset)
                ?? CGRect(origin: .zero, size: fallbackSize)
        case .custom:
            if let persistedCustomFrame,
               let valid = validatedCustomFrame(persistedCustomFrame, width: width, screens: screens) {
                return valid
            }
            // First custom frame, or its display is gone: start from the right edge.
            return CGRect(x: screen.visibleFrame.maxX - width,
                          y: screen.visibleFrame.minY,
                          width: width,
                          height: screen.visibleFrame.height)
        }
    }
}
