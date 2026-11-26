import CoreGraphics
import XCTest
@testable import OpenYoink

/// The drag-start state machine (DragGestureTracker) and the auto-show
/// session's decisions (DragAutoShowSession).
@MainActor
final class DragStartMonitorTests: XCTestCase {
    // MARK: - DragGestureTracker

    func testClickWithoutMovement_neverStartsDrag() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 103, y: 102))) // ~3.6 < 8
        XCTAssertEqual(tracker.phase, .pressing)
        // A plain click: no drag end reported.
        XCTAssertFalse(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testDrag_firesExactlyOnceWhenThresholdCrossed() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 105, y: 100))) // 5pt < 8
        // Exactly at the threshold (>=) confirms.
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 108, y: 100)))
        XCTAssertEqual(tracker.phase, .dragging)
        // Moving on after confirmation doesn't call back again.
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 200, y: 200)))
        // Mouse-up reports the drag end, then resets.
        XCTAssertTrue(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    func testDisplacementIsMeasuredFromOrigin_notPathLength() {
        // Circling in place: the path is long, but the distance from the start never
// reaches the threshold → no trigger.
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 104, y: 100)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 100, y: 104)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 96, y: 100)))
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 100, y: 96)))
        XCTAssertEqual(tracker.phase, .pressing)
    }

    func testDiagonalDisplacement_usesEuclideanDistance() {
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: .zero)
        XCTAssertFalse(tracker.mouseDragged(to: CGPoint(x: 4, y: 4))) // ~5.66 < 8
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 6, y: 6)))  // ~8.49 ≥ 8
    }

    func testNewMouseDown_rearmsAfterMissedMouseUp() {
        // The previous mouse-up was lost (defensive): a new press resets, so it can trigger again.
        var tracker = DragGestureTracker(threshold: 8)
        tracker.mouseDown(at: .zero)
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 20, y: 0)))
        tracker.mouseDown(at: CGPoint(x: 500, y: 500))
        XCTAssertEqual(tracker.phase, .pressing)
        XCTAssertTrue(tracker.mouseDragged(to: CGPoint(x: 508, y: 500)))
        XCTAssertTrue(tracker.mouseUp())
    }

    func testMouseUpWithoutPress_isNoOp() {
        var tracker = DragGestureTracker(threshold: 8)
        XCTAssertFalse(tracker.mouseUp())
        XCTAssertEqual(tracker.phase, .idle)
    }

    // MARK: - DragStartMonitor session completion

    func testSuccessfulDropSeesFinishedDragEvenWithoutMouseUp() throws {
        let monitor = DragStartMonitor(shouldSuppress: { false }, onDragStart: {}, onDragEnd: {})
        monitor.start()
        defer { monitor.stop() }
        beginDrag(on: monitor)
        XCTAssertTrue(monitor.isDragInProgress)

        let suite = "OpenYoinkDragEnd-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = SettingsStore(defaults: defaults)
        settings.dragOutRemovalPolicy = .keep
        let item = ShelfItem(kind: .file, displayName: "fixture")
        var activeAtDrop: Bool?
        let source = DragSessionController(
            contents: .init(items: [item], topLevelIDs: [item.id]),
            store: ShelfStore(items: [item]), settings: settings,
            recents: RecentItemsService(directoryURL: directory),
            onSuccessfulDrop: { activeAtDrop = monitor.isDragInProgress },
            onSourceDragEnded: { monitor.finishDrag(at: 3) }
        )

        source.completeDrag(operation: .copy)
        XCTAssertEqual(activeAtDrop, false)
    }

    func testSourceEndThenMouseUp_finishesOnceAndClearsStateBeforeCallback() {
        var startCount = 0
        var endCount = 0
        var activeWhenEnded: Bool?
        var monitor: DragStartMonitor!
        monitor = DragStartMonitor(
            shouldSuppress: { false },
            onDragStart: { startCount += 1 },
            onDragEnd: {
                activeWhenEnded = monitor.isDragInProgress
                endCount += 1
            }
        )
        monitor.start()
        defer { monitor.stop() }

        monitor.handle(eventType: .leftMouseDown,
                       at: CGPoint(x: 100, y: 100),
                       timestamp: 1,
                       snapshot: snapshot(changeCount: 10))
        monitor.handle(eventType: .leftMouseDragged,
                       at: CGPoint(x: 120, y: 100),
                       timestamp: 2,
                       snapshot: snapshot(changeCount: 11, hasFile: true))
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(monitor.isDragInProgress)

        monitor.finishDrag(at: 3)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(activeWhenEnded, false)
        XCTAssertFalse(monitor.isDragInProgress)

        monitor.handle(eventType: .leftMouseUp,
                       at: CGPoint(x: 120, y: 100),
                       timestamp: 2.5,
                       snapshot: snapshot(changeCount: 11, hasFile: true))
        monitor.finishDrag(at: 3.5)
        XCTAssertEqual(endCount, 1)
    }

    func testMouseUpThenSourceEnd_finishesOnce() {
        var startCount = 0
        var endCount = 0
        let monitor = DragStartMonitor(
            shouldSuppress: { false },
            onDragStart: { startCount += 1 },
            onDragEnd: { endCount += 1 }
        )
        monitor.start()
        defer { monitor.stop() }

        beginDrag(on: monitor)
        monitor.handle(eventType: .leftMouseUp,
                       at: CGPoint(x: 120, y: 100),
                       timestamp: 3,
                       snapshot: snapshot(changeCount: 11, hasFile: true))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(monitor.isDragInProgress)

        monitor.finishDrag(at: 3.1)
        XCTAssertEqual(endCount, 1)
    }

    func testFinishWithoutMouseUp_allowsNewDrag() {
        var startCount = 0
        var endCount = 0
        let monitor = DragStartMonitor(
            shouldSuppress: { false },
            onDragStart: { startCount += 1 },
            onDragEnd: { endCount += 1 }
        )
        monitor.start()
        defer { monitor.stop() }

        beginDrag(on: monitor)
        monitor.finishDrag(at: 3)
        monitor.finishDrag(at: 3.1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(monitor.isDragInProgress)

        monitor.handle(eventType: .leftMouseDown,
                       at: CGPoint(x: 200, y: 200),
                       timestamp: 4,
                       snapshot: snapshot(changeCount: 20))
        monitor.handle(eventType: .leftMouseDragged,
                       at: CGPoint(x: 220, y: 200),
                       timestamp: 5,
                       snapshot: snapshot(changeCount: 21, hasFile: true))
        XCTAssertEqual(startCount, 2)
        XCTAssertTrue(monitor.isDragInProgress)
    }

    func testStaleQueuedEventsAfterSourceEnd_doNotResurrectDrag() {
        var startCount = 0
        var endCount = 0
        let monitor = DragStartMonitor(
            shouldSuppress: { false },
            onDragStart: { startCount += 1 },
            onDragEnd: { endCount += 1 }
        )
        monitor.start()
        defer { monitor.stop() }

        beginDrag(on: monitor)
        monitor.finishDrag(at: 3)
        XCTAssertEqual(endCount, 1)

        // These represent monitor Tasks queued before the source-end callback
        // but scheduled to run after it.
        monitor.handle(eventType: .leftMouseDown,
                       at: CGPoint(x: 100, y: 100),
                       timestamp: 1.5,
                       snapshot: snapshot(changeCount: 10))
        monitor.handle(eventType: .leftMouseDragged,
                       at: CGPoint(x: 120, y: 100),
                       timestamp: 2.5,
                       snapshot: snapshot(changeCount: 11, hasFile: true))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(monitor.isDragInProgress)

        monitor.handle(eventType: .leftMouseDown,
                       at: CGPoint(x: 200, y: 200),
                       timestamp: 4,
                       snapshot: snapshot(changeCount: 20))
        monitor.handle(eventType: .leftMouseDragged,
                       at: CGPoint(x: 220, y: 200),
                       timestamp: 5,
                       snapshot: snapshot(changeCount: 21, hasFile: true))
        XCTAssertEqual(startCount, 2)
        XCTAssertTrue(monitor.isDragInProgress)
    }

    // MARK: - DragAutoShowSession

    func testAutoShow_dragEndedWithoutImport_requestsHide() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        XCTAssertTrue(session.dragEnded())
        // The session resets after ending: another mouse-up requests nothing.
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_importDuringDrag_keepsShelfByDefault() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_importDuringDrag_hidesWhenDisabled() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        XCTAssertTrue(session.dragEnded(keepShelfOpenAfterDrop: false))
    }

    func testAutoShow_mouseUpBeforeAcceptedDrop_keepsShelfWithoutTimeout() {
        var session = destinationSession()
        XCTAssertFalse(session.dragEnded())
        XCTAssertFalse(session.isDragging)
        XCTAssertTrue(session.shownAutomatically, "Retain ownership until the real destination callback")
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
        XCTAssertEqual(session, DragAutoShowSession())
    }

    func testAutoShow_mouseUpBeforeAcceptedDrop_hidesOnlyAfterImportWhenDisabled() {
        var session = destinationSession()
        XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: false))
        XCTAssertTrue(session.destinationEnded(sequenceNumber: 10, accepted: true))
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
    }

    func testAutoShow_destinationBeforeMouseUp_respectsBothSettings() {
        for keep in [true, false] {
            var session = destinationSession()
            XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
            XCTAssertTrue(session.isDragging, "Never hide while the global drag is active")
            XCTAssertEqual(session.dragEnded(keepShelfOpenAfterDrop: keep), !keep)
            XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: keep))
        }
    }

    func testAutoShow_rejectedCancelledOrDroppedElsewhere_hidesInEitherCallbackOrder() {
        for keep in [true, false] {
            var early = destinationSession()
            XCTAssertFalse(early.destinationEnded(sequenceNumber: 10, accepted: false))
            XCTAssertTrue(early.dragEnded(keepShelfOpenAfterDrop: keep))
            var late = destinationSession()
            XCTAssertFalse(late.dragEnded(keepShelfOpenAfterDrop: keep))
            XCTAssertTrue(late.destinationEnded(sequenceNumber: 10, accepted: false))
        }
    }

    func testAutoShow_duplicateDestinationEnd_doesNotOverwriteAcceptance() {
        var session = destinationSession()
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_oldCallbackCannotHideNewDrag() {
        var session = destinationSession()
        XCTAssertFalse(session.dragEnded())
        session.dragBegan()
        session.markShownAutomatically()
        session.destinationEntered(sequenceNumber: 11)
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
        XCTAssertTrue(session.isDragging)
        XCTAssertFalse(session.dragEnded())
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
        XCTAssertTrue(session.destinationEnded(sequenceNumber: 11, accepted: false))
    }

    func testAutoShow_explicitShowOrHideCancelsPendingAutomaticHide() {
        for accepted in [true, false] {
            var session = destinationSession()
            XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: false))
            session.cancelAutomaticHide()
            XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: accepted))
        }
    }

    func testAutoShow_manualPresentationDuringDragTakesOwnership() {
        var session = destinationSession()
        session.cancelAutomaticHide()
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
        XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: false))
    }

    func testAutoShow_unrelatedImportDoesNotTurnRejectedDestinationIntoSuccess() {
        var session = destinationSession()
        session.noteImport()
        XCTAssertFalse(session.dragEnded())
        XCTAssertTrue(session.destinationEnded(sequenceNumber: 10, accepted: false))
    }

    func testAutoShow_destinationOutsideTrackedDragDoesNotAcquireOwnership() {
        var session = DragAutoShowSession()
        session.destinationEntered(sequenceNumber: 10)
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: false))
        XCTAssertEqual(session, DragAutoShowSession())
    }

    func testAutoShow_manuallyVisibleDestinationNeverHides() {
        for accepted in [true, false] {
            var session = DragAutoShowSession()
            session.dragBegan()
            session.destinationEntered(sequenceNumber: 10)
            XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: false))
            XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: accepted))
        }
    }

    func testAutoShow_repeatedEntryKeepsAcceptedOutcome() {
        var session = destinationSession()
        session.destinationEntered(sequenceNumber: 10)
        XCTAssertFalse(session.destinationEnded(sequenceNumber: 10, accepted: true))
        session.destinationEntered(sequenceNumber: 10)
        XCTAssertFalse(session.dragEnded())
    }

    private func destinationSession() -> DragAutoShowSession {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.destinationEntered(sequenceNumber: 10)
        return session
    }

    func testAutoShow_importDuringDrag_keepsShelfWhenConfigured() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        XCTAssertFalse(session.dragEnded(keepShelfOpenAfterDrop: true))
    }

    func testAutoShow_markedOutsideDrag_isIgnored() {
        // Showing outside a drag (hot key, clipboard save) is explicit and never
// auto-hidden.
        var session = DragAutoShowSession()
        session.markShownAutomatically()
        XCTAssertFalse(session.shownAutomatically)
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_shelfVisibleBeforeDrag_staysUntouched() {
        // The shelf was visible before the drag (opened by hand): the caller
// doesn't mark it, and it stays after the drag.
        var session = DragAutoShowSession()
        session.dragBegan()
        // (no markShownAutomatically, matching the visibility guard in the caller)
        XCTAssertFalse(session.dragEnded())
    }

    func testAutoShow_newDragResetsPreviousSession() {
        var session = DragAutoShowSession()
        session.dragBegan()
        session.markShownAutomatically()
        session.noteImport()
        // A new drag resets every mark: a drag-shown shelf with no import still hides.
        session.dragBegan()
        session.markShownAutomatically()
        XCTAssertTrue(session.dragEnded())
    }

    private func beginDrag(on monitor: DragStartMonitor) {
        monitor.handle(eventType: .leftMouseDown,
                       at: CGPoint(x: 100, y: 100),
                       timestamp: 1,
                       snapshot: snapshot(changeCount: 10))
        monitor.handle(eventType: .leftMouseDragged,
                       at: CGPoint(x: 120, y: 100),
                       timestamp: 2,
                       snapshot: snapshot(changeCount: 11, hasFile: true))
    }

    private func snapshot(changeCount: Int, hasFile: Bool = false) -> DragPasteboardSnapshot {
        DragPasteboardSnapshot(
            changeCount: changeCount,
            typeIdentifiers: hasFile ? [PasteboardTypes.fileURL.rawValue] : []
        )
    }
}
