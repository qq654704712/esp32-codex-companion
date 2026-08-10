@testable import CodexCompanionCore
import XCTest

final class USBControlProtocolTests: XCTestCase {
    func testUSBControlDeviceMatcherAcceptsCompanionUACSideband() {
        XCTAssertTrue(USBControlDeviceMatcher.accepts(USBSerialDeviceIdentity(
            path: "/dev/cu.usbmodem-companion",
            vendorID: 0x303A,
            productID: 0x8001,
            productName: "Codex Companion USB Mic"
        )))
    }

    func testUSBControlDeviceMatcherRejectsNativeSerialJTAGPort() {
        XCTAssertFalse(USBControlDeviceMatcher.accepts(USBSerialDeviceIdentity(
            path: "/dev/cu.usbmodem4101",
            vendorID: 0x303A,
            productID: 0x1001,
            productName: "USB JTAG/serial debug unit"
        )))
    }

    func testUSBControlDeviceMatcherRejectsUnknownSerialAdapters() {
        XCTAssertFalse(USBControlDeviceMatcher.accepts(USBSerialDeviceIdentity(
            path: "/dev/cu.usbserial-unknown",
            vendorID: nil,
            productID: nil,
            productName: nil
        )))
    }

    func testHeartbeatEndsWithARealLineFeed() {
        XCTAssertEqual(Array(USBControlProtocol.heartbeat.utf8), [0x48, 0x3A, 0x31, 0x0A])
    }

    func testReturnRequestMatchesFirmwareSidebandLine() {
        XCTAssertEqual(USBControlProtocol.returnRequest, "K:R")
    }

    func testTaskEventsAreIndependentCompleteLines() {
        XCTAssertEqual(USBControlProtocol.taskEvent(.started), "E:S\n")
        XCTAssertEqual(USBControlProtocol.taskEvent(.completed), "E:D\n")
    }

    func testPromptAndWeatherBinaryPayloadsUseBoundedBase64Lines() {
        let payload = Data([0, 1, 2, 0xFF])
        XCTAssertEqual(USBControlProtocol.promptOpen(payload), "P:AAEC/w==\n")
        XCTAssertEqual(USBControlProtocol.weather(payload), "W:AAEC/w==\n")
        XCTAssertEqual(USBControlProtocol.promptClose, "C:P\n")
    }

    func testWeatherConfigurationUsesReadableUSBLine() {
        let config = DeviceWeatherConfigurationPayload(
            enabled: true, usesCelsius: false, refreshMinutes: 30
        )
        XCTAssertEqual(USBControlProtocol.weatherConfiguration(config), "G:1:0:30\n")
    }

    func testEveryDeviceStateIsEncodedAsOneCompleteLine() {
        let states: [DeviceState] = [
            .disconnected, .idle, .sessionStarting, .working, .completed,
            .error, .approvalRequired, .inputRequired, .confirmationRequired,
            .listening, .voiceError, .writing, .running,
        ]

        XCTAssertEqual(states.map(USBControlProtocol.state), [
            "S:0\n", "S:1\n", "S:2\n", "S:3\n", "S:4\n", "S:5\n",
            "S:6\n", "S:7\n", "S:8\n", "S:9\n", "S:A\n", "S:B\n", "S:C\n",
        ])
    }

    func testMirroredHIDAndCDCEdgesAreDeduplicated() {
        var edges = USBButtonEdgeDeduplicator()

        XCTAssertEqual(edges.action(for: true, at: 1), .down)
        XCTAssertNil(edges.action(for: true, at: 1.01))
        XCTAssertTrue(edges.isDown)
        XCTAssertEqual(edges.action(for: false, at: 2), .up)
        XCTAssertNil(edges.action(for: false, at: 2.01))
        XCTAssertFalse(edges.isDown)
    }

    func testMechanicalReboundIsIgnoredUntilRearmWindowEnds() {
        var edges = USBButtonEdgeDeduplicator()

        XCTAssertEqual(edges.action(for: true, at: 1), .down)
        XCTAssertEqual(edges.action(for: false, at: 2), .up)
        XCTAssertNil(edges.action(for: true, at: 2.1))
        XCTAssertNil(edges.action(for: false, at: 2.2))
        XCTAssertEqual(
            edges.action(for: true, at: 2 + USBButtonEdgeDeduplicator.rearmInterval),
            .down
        )
    }

    func testResetRecoversFromMissingReleaseEdge() {
        var edges = USBButtonEdgeDeduplicator()

        XCTAssertEqual(edges.action(for: true, at: 1), .down)
        edges.reset()

        XCTAssertFalse(edges.isDown)
        XCTAssertEqual(edges.action(for: true, at: 1.1), .down)
    }
}
