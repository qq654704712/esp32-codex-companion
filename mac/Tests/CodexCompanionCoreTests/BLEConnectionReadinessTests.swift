import XCTest
@testable import CodexCompanionCore

final class BLEConnectionReadinessTests: XCTestCase {
    func testRequiresBothNotificationsAndProvisioning() {
        var readiness = BLEConnectionReadiness()
        XCTAssertFalse(readiness.isReady)
        readiness.controlNotifications = true
        readiness.audioNotifications = true
        XCTAssertFalse(readiness.isReady)
        readiness.provisioned = true
        XCTAssertTrue(readiness.isReady)
    }

    func testResetClearsEveryGate() {
        var readiness = BLEConnectionReadiness(
            controlNotifications: true,
            audioNotifications: true,
            provisioned: true
        )
        readiness.reset()
        XCTAssertFalse(readiness.controlNotifications)
        XCTAssertFalse(readiness.audioNotifications)
        XCTAssertFalse(readiness.provisioned)
        XCTAssertFalse(readiness.isReady)
    }
}
