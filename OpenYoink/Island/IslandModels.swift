import Foundation
import Observation
@_exported import OpenYoinkModuleCore

extension IslandModuleID {
    static let shelf = Self(rawValue: "shelf")
    static let transfers = Self(rawValue: "transfers")
    static let timer = Self(rawValue: "timer")
    static let battery = Self(rawValue: "battery")
    static let media = Self(rawValue: "media")
    static let system = Self(rawValue: "system")
    static let folders = Self(rawValue: "folders")
    static let clipboard = Self(rawValue: "clipboard")
    static let aiUsage = Self(rawValue: "aiUsage")
}

enum IslandSurfaceState: Equatable, Sendable {
    case hidden
    case compact
    case expanded
    case pinned

    var isExpanded: Bool {
        self == .expanded || self == .pinned
    }
}

/// Shared timing keeps the SwiftUI silhouette transition and the AppKit panel
/// resize in one rhythm. On collapse the visible surface finishes tucking into
/// the notch before the now-transparent window footprint is reduced.
enum IslandMotion {
    /// Match the Web demo's continuous notch morph: the AppKit canvas and the
    /// SwiftUI reveal share a single, velocity-preserving visual rhythm.
    static let expandContentDuration: TimeInterval = 0.38
    static let expandWindowDuration: TimeInterval = 0.38
    /// Exit remains a little quicker, but still visibly morphs back into the
    /// compact surface rather than disappearing before the window shrinks.
    static let collapseContentDuration: TimeInterval = 0.28
    static let collapseWindowDuration: TimeInterval = 0.30
}

/// Internal-only module contract. v1.4.x deliberately does not load external
/// bundles; the protocol keeps first-party lifecycles consistent and gives a
/// future SDK a stable conceptual boundary.
@MainActor
protocol IslandModule: AnyObject {
    var descriptor: IslandModuleDescriptor { get }
    func start()
    func stop()
}

@MainActor
@Observable
final class IslandModuleRegistry {
    private(set) var descriptors: [IslandModuleDescriptor] = [
        .init(id: .shelf, title: String(localized: "Shelf"),
              systemImage: "tray.full", order: 0, isCore: true),
        .init(id: .transfers, title: String(localized: "Transfers"),
              systemImage: "arrow.up.arrow.down", order: 1, isCore: true),
        .init(id: .timer, title: String(localized: "Timer"),
              systemImage: "timer", order: 2, isCore: false),
        .init(id: .battery, title: String(localized: "Battery"),
              systemImage: "battery.75percent", order: 3, isCore: false),
        .init(id: .system, title: String(localized: "System Status"),
              systemImage: "gauge.with.dots.needle.67percent", order: 4, isCore: false),
        .init(id: .media, title: String(localized: "Now Playing"),
              systemImage: "music.note", order: 5, isCore: false),
        .init(id: .folders, title: String(localized: "Quick Access"),
              systemImage: "folder", order: 6, isCore: false),
        .init(id: .clipboard, title: String(localized: "Clipboard History"),
              systemImage: "doc.on.clipboard", order: 7, isCore: false),
        AIUsageModuleStore.moduleDescriptor,
    ]

    private(set) var enabledIDs: Set<IslandModuleID> = [.shelf, .transfers]

    func apply(settings: SettingsStore) {
        enabledIDs = Set(settings.islandModuleConfiguration.enabledModuleIDs)
    }

    var enabledDescriptors: [IslandModuleDescriptor] {
        descriptors
            .filter { enabledIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
    }

    func isEnabled(_ id: IslandModuleID) -> Bool {
        enabledIDs.contains(id)
    }

    func descriptor(for id: IslandModuleID) -> IslandModuleDescriptor? {
        descriptors.first { $0.id == id }
    }
}

@MainActor
@Observable
final class IslandActivityCoordinator {
    private(set) var surfaceState: IslandSurfaceState = .compact
    /// A completion belongs to one specific transition, even when rapid
    /// close/open/close gestures return to the same surface state.
    private(set) var surfaceTransitionID: UInt64 = 0
    private(set) var isSurfaceTransitionPending = false
    var currentLayout: IslandGeometryResolver.Layout?
    /// Floating (no-notch) Island only: pill, idle dot, or hidden. Visual
    /// state owned by the window controller, which also sizes the panel.
    var floatingPresentation: IslandFloatingPresentation = .capsule
    /// Visual-only hover state. It intentionally does not call
    /// `onStateDidChange`, because pointer movement must never resize the panel.
    var isPointerHovering = false
    /// A deliberate collapse must win over hover reveal until the pointer has
    /// actually left the compact surface. Without this latch, the mouse-move
    /// monitor immediately schedules another expansion while the click is
    /// still resting on the notch, which can look like the click selected the
    /// current activity's module instead of collapsing.
    private(set) var isHoverRevealSuppressed = false
    var selectedModule: IslandModuleID = .shelf {
        didSet {
            guard oldValue != selectedModule else { return }
            onStateDidChange?()
        }
    }
    private(set) var activities: [String: IslandActivity] = [:]
    private var stateBeforeDrag: IslandSurfaceState?
    private var moduleBeforeDrag: IslandModuleID?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var spotlightTask: Task<Void, Never>?
    @ObservationIgnored private var firstPublishedAt: [String: Date] = [:]
    private var spotlightRevision: UInt64 = 0

    var onSurfaceStateWillChange: (@MainActor (
        IslandSurfaceState,
        IslandSurfaceState
    ) -> Void)?
    var onStateDidChange: (@MainActor () -> Void)?
    @ObservationIgnored var onSurfaceAnimationCompleted: (@MainActor () -> Void)?

    func setSurfaceState(_ state: IslandSurfaceState) {
        guard surfaceState != state else { return }
        let previousState = surfaceState
        onSurfaceStateWillChange?(previousState, state)
        surfaceState = state
        surfaceTransitionID &+= 1
        isSurfaceTransitionPending = true
        if state.isExpanded {
            isPointerHovering = false
            isHoverRevealSuppressed = false
        }
        onStateDidChange?()
    }

    func completeSurfaceTransition(_ transitionID: UInt64) {
        guard transitionID == surfaceTransitionID, isSurfaceTransitionPending else { return }
        isSurfaceTransitionPending = false
        onSurfaceAnimationCompleted?()
    }

    func setPointerHovering(_ hovering: Bool) {
        // Clear the deliberate-collapse latch on exit even if the visual
        // hover value was already false. The next genuine pointer entry may
        // then reveal the Island normally.
        if !hovering { isHoverRevealSuppressed = false }
        guard isPointerHovering != hovering else { return }
        isPointerHovering = hovering
    }

    var canRevealOnHover: Bool {
        !isHoverRevealSuppressed
    }

    func show(module: IslandModuleID = .shelf, pinned: Bool = false) {
        selectedModule = module
        setSurfaceState(pinned ? .pinned : .expanded)
    }

    func toggle() {
        if surfaceState.isExpanded {
            collapse()
        } else {
            show(module: selectedModule)
        }
    }

    func collapse(suppressHoverUntilPointerExit: Bool = true) {
        isHoverRevealSuppressed = suppressHoverUntilPointerExit
        setSurfaceState(.compact)
    }

    func setPinned(_ pinned: Bool) {
        setSurfaceState(pinned ? .pinned : .expanded)
    }

    func hide() {
        setSurfaceState(.hidden)
    }

    func publish(_ activity: IslandActivity?, at date: Date = Date()) {
        guard let activity else { return }
        if activities[activity.id] == nil {
            // Republishing an alert with fresh numbers must not restart its
            // spotlight, or a recurring warning could hold the notch forever.
            firstPublishedAt[activity.id] = date
        }
        activities[activity.id] = activity
        scheduleExpiry()
        scheduleSpotlightEnd(at: date)
        onStateDidChange?()
    }

    func removeActivity(id: String) {
        guard activities.removeValue(forKey: id) != nil else { return }
        firstPublishedAt[id] = nil
        scheduleExpiry()
        onStateDidChange?()
    }

    func removeActivities(for moduleID: IslandModuleID) {
        let previousCount = activities.count
        activities = activities.filter { $0.value.moduleID != moduleID }
        if activities.count != previousCount {
            forgetRemovedActivities()
            scheduleExpiry()
            onStateDidChange?()
        }
    }

    /// Advisory alerts (AI limits, system load, power changes) announce
    /// themselves in the compact Island for this long, then hand it back to
    /// Now Playing. They stay published, so the module still shows them and
    /// they return to the notch once media goes away. Critical battery,
    /// finished timers, transfers and drags keep outranking media.
    static let advisorySpotlightDuration: TimeInterval = 8

    func primaryActivity(at date: Date = Date()) -> IslandActivity? {
        // Read so SwiftUI re-evaluates when a spotlight ends, which changes the
        // answer without any activity changing.
        _ = spotlightRevision
        let candidates = activities.values
            .filter { $0.isActive(at: date) }
            .filter { activity in
                activity.priority != .selectedModule
                    || activity.moduleID == selectedModule
            }
        let hasMedia = candidates.contains { $0.priority == .nowPlaying }
        func rank(_ activity: IslandActivity) -> Int {
            guard hasMedia, isAdvisory(activity), !isInSpotlight(activity, at: date) else {
                return activity.priority.rawValue
            }
            return IslandActivityPriority.nowPlaying.rawValue - 1
        }
        return candidates.max { lhs, rhs in
            let lhsRank = rank(lhs), rhsRank = rank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id < rhs.id
        }
    }

    func pruneExpired(at date: Date = Date()) {
        let previousCount = activities.count
        activities = activities.filter { $0.value.isActive(at: date) }
        forgetRemovedActivities()
        scheduleExpiry()
        if activities.count != previousCount { onStateDidChange?() }
    }

    private func isAdvisory(_ activity: IslandActivity) -> Bool {
        activity.priority == .powerChange || activity.priority == .systemWarning
    }

    private func isInSpotlight(_ activity: IslandActivity, at date: Date) -> Bool {
        guard let start = firstPublishedAt[activity.id] else { return false }
        return date.timeIntervalSince(start) < Self.advisorySpotlightDuration
    }

    private func forgetRemovedActivities() {
        firstPublishedAt = firstPublishedAt.filter { activities[$0.key] != nil }
    }

    private func scheduleSpotlightEnd(at date: Date) {
        spotlightTask?.cancel()
        let pendingEnds = activities.values
            .filter(isAdvisory)
            .compactMap { firstPublishedAt[$0.id] }
            .map { $0.addingTimeInterval(Self.advisorySpotlightDuration) }
            .filter { $0 > date }
        guard let nextEnd = pendingEnds.min() else {
            spotlightTask = nil
            return
        }
        let delay = nextEnd.timeIntervalSince(date)
        spotlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.spotlightRevision &+= 1
            self.scheduleSpotlightEnd(at: Date())
            self.onStateDidChange?()
        }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let nextExpiry = activities.values.compactMap(\.expiresAt).min() else {
            expiryTask = nil
            return
        }
        let delay = max(0, nextExpiry.timeIntervalSinceNow)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pruneExpired()
        }
    }

    func beginDrag() {
        if stateBeforeDrag == nil {
            stateBeforeDrag = surfaceState
            moduleBeforeDrag = selectedModule
        }
        selectedModule = .shelf
        publish(.init(id: "drag", moduleID: .shelf, priority: .userDrag,
                      title: String(localized: "Drop into OpenYoink"), detail: nil,
                      systemImage: "arrow.down.to.line", expiresAt: nil))
        setSurfaceState(.expanded)
    }

    func endDrag(imported: Bool) {
        removeActivity(id: "drag")
        defer {
            stateBeforeDrag = nil
            moduleBeforeDrag = nil
        }
        guard !imported else {
            setSurfaceState(.expanded)
            return
        }
        if let moduleBeforeDrag { selectedModule = moduleBeforeDrag }
        setSurfaceState(stateBeforeDrag ?? .compact)
    }
}
