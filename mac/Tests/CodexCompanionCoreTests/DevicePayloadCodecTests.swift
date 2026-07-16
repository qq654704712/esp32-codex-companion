import Foundation
import XCTest
@testable import CodexCompanionCore

final class DevicePayloadCodecTests: XCTestCase {
    func testStatePayload() throws {
        XCTAssertEqual(try DevicePayloadCodec.state(.working), Data([0xA1, 0x00, 0x03]))
        XCTAssertEqual(try DevicePayloadCodec.decodeState(Data([0xA1, 0x00, 0x03])), .working)
    }

    func testQuotaPayload() throws {
        let data = try DevicePayloadCodec.quota(fiveHour: nil, week: 72)
        XCTAssertEqual(data, Data([0xA2, 0x00, 0x18, 0xFF, 0x01, 0x18, 0x48]))
        let decoded = try DevicePayloadCodec.decodeQuota(data)
        XCTAssertNil(decoded.fiveHour)
        XCTAssertEqual(decoded.week, 72)
    }

    func testHeartbeatCarriesQuotaFreshnessWithoutRepeatingQuotaValues() {
        XCTAssertEqual(DevicePayloadCodec.heartbeat(quotaFresh: true), Data([0xA1, 0x00, 0xF5]))
        XCTAssertEqual(DevicePayloadCodec.heartbeat(quotaFresh: false), Data([0xA1, 0x00, 0xF4]))
    }
}
