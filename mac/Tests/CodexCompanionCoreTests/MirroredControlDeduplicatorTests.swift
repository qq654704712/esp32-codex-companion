import XCTest
@testable import CodexCompanionCore

final class MirroredControlDeduplicatorTests: XCTestCase {
    func testExactMirroredPacketIsHandledOnlyOnce() {
        var deduplicator = MirroredControlDeduplicator(retention: 30, capacity: 4)
        let packet = Data([1, 2, 3])

        XCTAssertTrue(deduplicator.accept(packet, at: 10))
        XCTAssertFalse(deduplicator.accept(packet, at: 10.1))
        XCTAssertTrue(deduplicator.accept(Data([1, 2, 4]), at: 10.2))
    }

    func testExpiredPacketCanBeAcceptedAfterDeviceRestart() {
        var deduplicator = MirroredControlDeduplicator(retention: 2, capacity: 4)
        let packet = Data([9])

        XCTAssertTrue(deduplicator.accept(packet, at: 1))
        XCTAssertTrue(deduplicator.accept(packet, at: 4))
    }
}
