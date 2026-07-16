import XCTest
@testable import CodexCompanionCore

final class QuotaMapperTests: XCTestCase {
    func testQuotaWindowsMapByDurationNotPosition() {
        let windows = [
            RateLimitWindow(windowDurationMins: 10_080, usedPercent: 41, resetsAt: 200),
            RateLimitWindow(windowDurationMins: 300, usedPercent: 72.5, resetsAt: 100),
        ]

        let snapshot = QuotaMapper.map(windows: windows, updatedAt: 50)

        XCTAssertEqual(snapshot.fiveHourRemainingPercent, 27.5)
        XCTAssertEqual(snapshot.weekRemainingPercent, 59)
        XCTAssertEqual(snapshot.fiveHourResetsAt, 100)
        XCTAssertEqual(snapshot.weekResetsAt, 200)
    }

    func testQuotaValuesAreClampedAndMissingWindowsRemainNil() {
        let windows = [RateLimitWindow(windowDurationMins: 300, usedPercent: 130, resetsAt: nil)]

        let snapshot = QuotaMapper.map(windows: windows, updatedAt: 50)

        XCTAssertEqual(snapshot.fiveHourRemainingPercent, 0)
        XCTAssertNil(snapshot.weekRemainingPercent)
    }
}
