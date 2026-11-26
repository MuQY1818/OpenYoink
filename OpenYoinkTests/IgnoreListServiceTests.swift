import XCTest
@testable import OpenYoink

final class IgnoreListServiceTests: XCTestCase {
    func testExactMatch_isIgnored() {
        XCTAssertTrue(IgnoreListService.isIgnored(bundleID: "com.apple.Safari",
                                                  in: ["com.apple.Safari", "com.apple.finder"]))
    }

    func testCaseInsensitiveMatch_isIgnored() {
        XCTAssertTrue(IgnoreListService.isIgnored(bundleID: "COM.Apple.SAFARI",
                                                  in: ["com.apple.safari"]))
    }

    func testWhitespacePaddedListEntry_matches() {
        XCTAssertTrue(IgnoreListService.isIgnored(bundleID: "com.apple.safari",
                                                  in: ["  com.apple.safari  "]))
    }

    func testUnlistedApp_isNotIgnored() {
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: "com.apple.finder",
                                                   in: ["com.apple.safari"]))
    }

    func testEmptyList_neverMatches() {
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: "com.apple.safari", in: []))
    }

    func testNilOrEmptyBundleID_neverMatches() {
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: nil, in: ["com.apple.safari"]))
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: "", in: ["com.apple.safari"]))
        XCTAssertFalse(IgnoreListService.isIgnored(bundleID: "   ", in: ["com.apple.safari"]))
    }
}
