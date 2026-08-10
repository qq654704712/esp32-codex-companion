import Foundation
import XCTest
@testable import CodexCompanionCore

final class WeatherSyncTests: XCTestCase {
    func testConfigurationStoreNormalizesCityAndRefreshInterval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WeatherConfigurationStore(url: root.appendingPathComponent("weather.json"))
        try store.save(WeatherConfiguration(
            city: "  上海  ", enabled: true, usesCelsius: false, refreshMinutes: 45
        ))
        XCTAssertEqual(store.load(), WeatherConfiguration(
            city: "上海", enabled: true, usesCelsius: false, refreshMinutes: 30
        ))
    }

    func testSnapshotBuildsBoundedDevicePayload() {
        let snapshot = WeatherSnapshot(
            city: String(repeating: "上", count: 60),
            temperatureTenthsCelsius: 253,
            weatherCode: 2
        )
        XCTAssertLessThanOrEqual(snapshot.devicePayload.city.utf8.count, 48)
        XCTAssertFalse(snapshot.devicePayload.city.isEmpty)
        XCTAssertTrue(snapshot.devicePayload.city.unicodeScalars.allSatisfy(\.isASCII))
        XCTAssertEqual(snapshot.devicePayload.city.lowercased(), "shang shang shang shang shang shang shang shang")
        XCTAssertEqual(snapshot.devicePayload.temperatureTenthsCelsius, 253)
    }

    func testSnapshotTransliteratesDynamicChineseCityForEmbeddedFont() {
        let snapshot = WeatherSnapshot(
            city: "上海",
            temperatureTenthsCelsius: 320,
            weatherCode: 2
        )

        XCTAssertEqual(snapshot.devicePayload.city.lowercased(), "shang hai")
        XCTAssertTrue(snapshot.devicePayload.city.unicodeScalars.allSatisfy(\.isASCII))
    }
}
