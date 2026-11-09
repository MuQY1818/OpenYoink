import XCTest
@testable import OpenYoink

@MainActor
final class IslandActivityCoordinatorTests: XCTestCase {
    func testRegistryCanDisableShelfWithoutDisablingIslandModules() throws {
        let suiteName = "IslandModuleRegistryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.islandShelfEnabled = false
        settings.islandTimerEnabled = true
        settings.islandBatteryEnabled = true

        let registry = IslandModuleRegistry()
        registry.apply(settings: settings)

        XCTAssertFalse(registry.isEnabled(.shelf))
        XCTAssertTrue(registry.isEnabled(.transfers))
        XCTAssertTrue(registry.isEnabled(.timer))
        XCTAssertTrue(registry.isEnabled(.battery))
    }

    func testPriorityPicksDragBeforeTransferAndTimer() {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(activity(id: "timer", module: .timer, priority: .timerFinished))
        coordinator.publish(activity(id: "transfer", module: .transfers, priority: .transfer))
        coordinator.publish(activity(id: "drag", module: .shelf, priority: .userDrag))
        XCTAssertEqual(coordinator.primaryActivity()?.id, "drag")
        coordinator.removeActivity(id: "drag")
        XCTAssertEqual(coordinator.primaryActivity()?.id, "transfer")
    }

    func testAdvisoryAlertYieldsToNowPlayingAfterItsSpotlight() {
        let coordinator = IslandActivityCoordinator()
        let start = Date(timeIntervalSince1970: 1_000)
        coordinator.publish(activity(id: "media", module: .media, priority: .nowPlaying), at: start)
        coordinator.publish(activity(id: "ai", module: .aiUsage, priority: .systemWarning), at: start)

        XCTAssertEqual(coordinator.primaryActivity(at: start.addingTimeInterval(1))?.id, "ai")
        let after = start.addingTimeInterval(IslandActivityCoordinator.advisorySpotlightDuration + 1)
        XCTAssertEqual(coordinator.primaryActivity(at: after)?.id, "media")

        // Republishing fresh numbers must not restart the spotlight.
        coordinator.publish(activity(id: "ai", module: .aiUsage, priority: .systemWarning), at: after)
        XCTAssertEqual(coordinator.primaryActivity(at: after)?.id, "media")

        // Without media, the alert keeps the compact Island.
        coordinator.removeActivity(id: "media")
        XCTAssertEqual(coordinator.primaryActivity(at: after)?.id, "ai")
    }

    func testCriticalActivitiesStillOutrankNowPlaying() {
        let coordinator = IslandActivityCoordinator()
        let start = Date(timeIntervalSince1970: 1_000)
        coordinator.publish(activity(id: "media", module: .media, priority: .nowPlaying), at: start)
        coordinator.publish(activity(id: "battery", module: .battery, priority: .criticalBattery), at: start)
        let after = start.addingTimeInterval(IslandActivityCoordinator.advisorySpotlightDuration + 60)
        XCTAssertEqual(coordinator.primaryActivity(at: after)?.id, "battery")
    }

    func testSelectedModuleSummaryDoesNotOverrideAnotherModule() {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(activity(id: "timer", module: .timer,
                                     priority: .selectedModule))
        XCTAssertNil(coordinator.primaryActivity())
        coordinator.selectedModule = .timer
        XCTAssertEqual(coordinator.primaryActivity()?.id, "timer")
    }

    func testExpiredActivityIsIgnoredAndPruned() {
        let coordinator = IslandActivityCoordinator()
        let now = Date(timeIntervalSince1970: 100)
        coordinator.publish(.init(id: "expired", moduleID: .battery,
                                  priority: .powerChange, title: "Power", detail: nil,
                                  systemImage: "bolt", expiresAt: now.addingTimeInterval(-1)))
        XCTAssertNil(coordinator.primaryActivity(at: now))
        coordinator.pruneExpired(at: now)
        XCTAssertTrue(coordinator.activities.isEmpty)
    }

    func testExpiringActivityPrunesItselfWithoutPolling() async throws {
        let coordinator = IslandActivityCoordinator()
        coordinator.publish(.init(id: "brief", moduleID: .battery,
                                  priority: .powerChange, title: "Power", detail: nil,
                                  systemImage: "bolt",
                                  expiresAt: Date().addingTimeInterval(0.02)))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(coordinator.activities.isEmpty)
    }

    func testCancelledDragRestoresPreviousModuleAndState() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .timer, pinned: true)
        coordinator.beginDrag()
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
        coordinator.endDrag(imported: false)
        XCTAssertEqual(coordinator.selectedModule, .timer)
        XCTAssertEqual(coordinator.surfaceState, .pinned)
    }

    func testSuccessfulDropStaysExpandedOnShelf() {
        let coordinator = IslandActivityCoordinator()
        coordinator.collapse()
        coordinator.beginDrag()
        coordinator.endDrag(imported: true)
        XCTAssertEqual(coordinator.selectedModule, .shelf)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
    }

    func testDeliberateCollapseSuppressesHoverRevealUntilPointerExits() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .timer)

        coordinator.collapse()
        coordinator.setPointerHovering(true)

        XCTAssertEqual(coordinator.surfaceState, .compact)
        XCTAssertFalse(coordinator.canRevealOnHover)

        coordinator.setPointerHovering(false)
        XCTAssertTrue(coordinator.canRevealOnHover)
    }

    func testProgrammaticCollapseCanLeaveHoverRevealAvailable() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show(module: .shelf)

        coordinator.collapse(suppressHoverUntilPointerExit: false)

        XCTAssertEqual(coordinator.surfaceState, .compact)
        XCTAssertTrue(coordinator.canRevealOnHover)
    }

    func testExplicitShowClearsHoverRevealSuppression() {
        let coordinator = IslandActivityCoordinator()
        coordinator.collapse()
        XCTAssertFalse(coordinator.canRevealOnHover)

        coordinator.show(module: .media)

        XCTAssertTrue(coordinator.canRevealOnHover)
        XCTAssertEqual(coordinator.selectedModule, .media)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
    }

    func testSurfaceWillChangeCallbackRunsBeforeObservableMutation() {
        let coordinator = IslandActivityCoordinator()
        var callbackStates: [(IslandSurfaceState, IslandSurfaceState, IslandSurfaceState)] = []
        coordinator.onSurfaceStateWillChange = { oldState, newState in
            callbackStates.append((oldState, newState, coordinator.surfaceState))
        }

        coordinator.show(module: .media)

        XCTAssertEqual(callbackStates.count, 1)
        XCTAssertEqual(callbackStates.first?.0, .compact)
        XCTAssertEqual(callbackStates.first?.1, .expanded)
        XCTAssertEqual(callbackStates.first?.2, .compact)
        XCTAssertEqual(coordinator.surfaceState, .expanded)
    }

    func testCollapseWaitsForItsActualAnimationCompletion() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show()
        coordinator.completeSurfaceTransition(coordinator.surfaceTransitionID)
        coordinator.collapse()
        var completions = 0
        coordinator.onSurfaceAnimationCompleted = { completions += 1 }
        XCTAssertTrue(coordinator.isSurfaceTransitionPending)
        let collapseID = coordinator.surfaceTransitionID
        coordinator.publish(activity(id: "sample", module: .system, priority: .selectedModule))
        XCTAssertTrue(coordinator.isSurfaceTransitionPending)
        XCTAssertEqual(coordinator.surfaceTransitionID, collapseID)
        coordinator.completeSurfaceTransition(collapseID)
        coordinator.completeSurfaceTransition(collapseID)
        XCTAssertFalse(coordinator.isSurfaceTransitionPending)
        XCTAssertEqual(completions, 1)
    }

    func testOldCollapseCompletionCannotFinishANewerCollapse() {
        let coordinator = IslandActivityCoordinator()
        coordinator.show()
        coordinator.collapse()
        let oldCollapseID = coordinator.surfaceTransitionID
        coordinator.show()
        let reopenID = coordinator.surfaceTransitionID
        coordinator.collapse()
        let currentID = coordinator.surfaceTransitionID
        coordinator.completeSurfaceTransition(oldCollapseID)
        coordinator.completeSurfaceTransition(reopenID)
        XCTAssertTrue(coordinator.isSurfaceTransitionPending)
        XCTAssertEqual(coordinator.surfaceState, .compact)
        coordinator.completeSurfaceTransition(currentID)
        XCTAssertFalse(coordinator.isSurfaceTransitionPending)
    }

    private func activity(id: String, module: IslandModuleID,
                          priority: IslandActivityPriority) -> IslandActivity {
        .init(id: id, moduleID: module, priority: priority,
              title: id, detail: nil, systemImage: "circle", expiresAt: nil)
    }
}
