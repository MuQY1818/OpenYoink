import XCTest
@testable import OpenYoink

@MainActor
final class WorkflowUpgradeTests: XCTestCase {
    func testSearchMatchesNamesTextURLsAndStackChildren() {
        let file = ShelfItem(kind: .file, displayName: "Report.PDF")
        let text = ShelfItem(kind: .text, displayName: "Note", text: "meeting Tuesday")
        let url = ShelfItem(kind: .url, displayName: "Website", urlString: "https://example.com")
        let stack = ShelfItem(kind: .stack, displayName: "Bundle", children: [file, text])
        let store = ShelfStore(items: [stack, url])
        store.searchQuery = " TUESDAY "
        XCTAssertEqual(store.visibleItems.map(\.id), [stack.id])
        store.searchQuery = "REPORT"
        store.contentFilter = .files
        XCTAssertEqual(store.visibleItems.map(\.id), [stack.id])
        store.contentFilter = .links
        XCTAssertTrue(store.visibleItems.isEmpty)
        store.searchQuery = "example"
        XCTAssertEqual(store.visibleItems.map(\.id), [url.id])
        XCTAssertEqual(store.items.count, 2)
    }

    func testUndoRemovalPreservesNewItemsAndDoesNotUndoDelivery() {
        let a = ShelfItem(kind: .file, path: "/tmp/a", displayName: "a")
        let b = ShelfItem(kind: .text, displayName: "b", text: "b")
        let c = ShelfItem(kind: .file, displayName: "c")
        let store = ShelfStore(items: [a, b])
        store.removeForUser(ids: [a.id])
        XCTAssertTrue(store.undoProtectedPaths.contains("/tmp/a"))
        store.add(c)
        store.remove(ids: [b.id])
        XCTAssertTrue(store.undoLastRemoval())
        XCTAssertEqual(store.items.map(\.id), [a.id, c.id])
        XCTAssertFalse(store.canUndoRemoval)
        XCTAssertTrue(store.undoProtectedPaths.isEmpty)
    }

    func testUndoStackRemovalAndPreventResurrectingDeliveredManagedFile() {
        let a = ShelfItem(kind: .file, path: "/tmp/managed", displayName: "managed", isCut: true)
        let b = ShelfItem(kind: .file, displayName: "b")
        let stack = ShelfItem(kind: .stack, displayName: "stack", children: [a, b])
        let store = ShelfStore(items: [stack])
        XCTAssertTrue(store.removeChildrenForUser(ids: [b.id], fromStack: stack.id))
        XCTAssertEqual(store.items.first?.id, a.id)
        XCTAssertTrue(store.undoLastRemoval())
        XCTAssertEqual(store.items, [stack])
        _ = store.removeChildrenForUser(ids: [b.id], fromStack: stack.id)
        store.invalidateUndoForDeliveredItem(a.id)
        store.remove(ids: [a.id])
        XCTAssertFalse(store.undoLastRemoval())
        XCTAssertTrue(store.items.isEmpty)
    }

    func testUndoDoesNotDuplicateAnItemReaddedFromRecents() {
        let item = ShelfItem(kind: .text, displayName: "x")
        let store = ShelfStore(items: [item])
        store.removeForUser(ids: [item.id])
        store.add(item)
        XCTAssertFalse(store.undoLastRemoval())
        XCTAssertEqual(store.items.count, 1)
    }

    func testWorkflowPresetsPreservePrivacyDataAndUnknownModules() throws {
        let suite = "OpenYoinkWorkflowTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setIslandModuleEnabled(true, id: "future.module")
        settings.clipboardHistoryEnabled = false
        settings.clipboardHistoryPaused = true
        for preset in WorkflowPreset.allCases {
            settings.applyWorkflowPreset(preset)
            XCTAssertFalse(settings.clipboardHistoryEnabled)
            XCTAssertTrue(settings.clipboardHistoryPaused)
            XCTAssertTrue(settings.isIslandModuleEnabled("future.module"))
            XCTAssertFalse(settings.islandDragApproachEnabled)
            XCTAssertEqual(settings.islandEnabled, preset != .files)
        }
        XCTAssertTrue(settings.isIslandModuleEnabled(.folders))
        XCTAssertTrue(settings.isIslandModulePinned(.clipboard))
        settings.clipboardHistoryShortcut = nil
        XCTAssertNil(SettingsStore(defaults: defaults).clipboardHistoryShortcut)
    }

    func testAdaptiveIntervalsAndLockSleepSuppression() {
        XCTAssertEqual(ResourceUsagePolicy.batteryInterval(isExpanded: true, isConstrained: false), .seconds(2))
        XCTAssertEqual(ResourceUsagePolicy.batteryInterval(isExpanded: false, isConstrained: false), .seconds(15))
        XCTAssertEqual(ResourceUsagePolicy.batteryInterval(isExpanded: true, isConstrained: true), .seconds(30))
        XCTAssertEqual(ResourceUsagePolicy.mediaInterval(isExpanded: false, isConstrained: false, hasPlayer: true), .seconds(5))
        XCTAssertEqual(ResourceUsagePolicy.mediaInterval(isExpanded: true, isConstrained: false, hasPlayer: false), .seconds(15))
        XCTAssertFalse(ResourceUsagePolicy.samplingAllowed(isSleeping: true, isLocked: false))
        XCTAssertFalse(ResourceUsagePolicy.samplingAllowed(isSleeping: false, isLocked: true))
        XCTAssertTrue(ResourceUsagePolicy.samplingAllowed(isSleeping: false, isLocked: false))
    }

    func testFolderDropLocatorIgnoresClippedTiles() {
        let id = UUID()
        let viewport = CGRect(x: 0, y: 50, width: 200, height: 100)
        let tiles = [id: CGRect(x: 0, y: 30, width: 80, height: 60)]
        XCTAssertNil(FavoriteFolderDropLocator.target(at: .init(x: 20, y: 40), tiles: tiles,
                                                      viewport: viewport, addFrame: .zero))
        XCTAssertEqual(FavoriteFolderDropLocator.target(at: .init(x: 20, y: 60), tiles: tiles,
                                                       viewport: viewport, addFrame: .zero), .folder(id))
    }

    func testFolderCopyAcceptanceBypassesDragOutRemovalPolicy() throws {
        let suite = "OpenYoinkInternalCopy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.dragOutRemovalPolicy = .remove
        let item = ShelfItem(kind: .file, displayName: "keep on shelf", isCut: true)
        let store = ShelfStore(items: [item])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DragSessionController(contents: .init(items: [item], topLevelIDs: [item.id]),
                                           store: store, settings: settings,
                                           recents: RecentItemsService(directoryURL: directory))
        source.acceptedByFolderCopy = true
        source.completeDrag(operation: .copy)
        XCTAssertEqual(store.items, [item])
        XCTAssertFalse(store.canUndoRemoval)
    }
}
