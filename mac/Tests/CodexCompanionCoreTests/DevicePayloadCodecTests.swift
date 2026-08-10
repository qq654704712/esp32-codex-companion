import Foundation
import XCTest
@testable import CodexCompanionCore

final class DevicePayloadCodecTests: XCTestCase {
    func testStatePayload() throws {
        XCTAssertEqual(try DevicePayloadCodec.state(.working), Data([0xA1, 0x00, 0x03]))
        XCTAssertEqual(try DevicePayloadCodec.decodeState(Data([0xA1, 0x00, 0x03])), .working)
    }

    func testActivityPayloadCarriesConcurrentTaskCounts() throws {
        let payload = DeviceActivityPayload(
            state: .approvalRequired,
            activeTasks: 3,
            attentionTasks: 1,
            recentCompletedTasks: 2
        )
        let data = try DevicePayloadCodec.activity(payload)
        XCTAssertEqual(data, Data([0xA4, 0x00, 0x06, 0x01, 0x03, 0x02, 0x01, 0x03, 0x02]))
        XCTAssertEqual(try DevicePayloadCodec.decodeActivity(data), payload)
    }

    func testLegacyStateDecodesAsEmptyActivity() throws {
        let activity = try DevicePayloadCodec.decodeActivity(Data([0xA1, 0x00, 0x03]))
        XCTAssertEqual(activity.state, .working)
        XCTAssertEqual(activity.activeTasks, 0)
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

    func testTaskEventPayload() throws {
        XCTAssertEqual(DevicePayloadCodec.taskEvent(.started), Data([0xA1, 0x00, 0x00]))
        XCTAssertEqual(DevicePayloadCodec.taskEvent(.completed), Data([0xA1, 0x00, 0x01]))
        XCTAssertEqual(try DevicePayloadCodec.decodeTaskEvent(Data([0xA1, 0x00, 0x01])), .completed)
    }

    func testWeatherPayloadSupportsSignedTemperatureAndUTF8City() throws {
        let payload = DeviceWeatherPayload(
            city: "上海", temperatureTenthsCelsius: -35, weatherCode: 61
        )
        XCTAssertEqual(try DevicePayloadCodec.decodeWeather(
            DevicePayloadCodec.weather(payload)
        ), payload)
    }

    func testWeatherConfigurationRoundTrips() throws {
        let payload = DeviceWeatherConfigurationPayload(
            enabled: true, usesCelsius: false, refreshMinutes: 15
        )
        XCTAssertEqual(try DevicePayloadCodec.decodeWeatherConfiguration(
            DevicePayloadCodec.weatherConfiguration(payload)
        ), payload)
    }
}
