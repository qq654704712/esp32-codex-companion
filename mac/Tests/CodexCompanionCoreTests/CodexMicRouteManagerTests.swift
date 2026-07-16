import XCTest
@testable import CodexCompanionCore

final class CodexMicRouteManagerTests: XCTestCase {
    func testPrepareSwitchesToCodexMicAndRestoreReturnsPreviousDevice() throws {
        let api = RecordingCoreAudioAPI(defaultInput: 11, codexMic: 22)
        let manager = CodexMicRouteManager(api: api, confirmationAttempts: 1)

        try manager.prepareCodexMic()
        manager.restorePreviousRoute()

        XCTAssertEqual(api.setCalls, [22, 11])
    }

    func testMissingCodexMicDoesNotChangeDefaultDevice() {
        let api = RecordingCoreAudioAPI(defaultInput: 11, codexMic: nil)
        let manager = CodexMicRouteManager(api: api, confirmationAttempts: 1)

        XCTAssertThrowsError(try manager.prepareCodexMic()) { error in
            XCTAssertEqual(error as? AudioRouteError, .codexMicNotFound)
        }
        XCTAssertTrue(api.setCalls.isEmpty)
    }

    func testNativeUSBMicrophoneIsPreferredOverVirtualDriver() throws {
        let api = RecordingCoreAudioAPI(defaultInput: 11, codexMic: 22, usbMic: 33)
        let manager = CodexMicRouteManager(api: api, confirmationAttempts: 1)

        try manager.prepareCodexMic()

        XCTAssertEqual(api.setCalls, [33])
    }
}

private final class RecordingCoreAudioAPI: CoreAudioRoutingAPI {
    var current: UInt32
    let codexMic: UInt32?
    let usbMic: UInt32?
    var setCalls: [UInt32] = []

    init(defaultInput: UInt32, codexMic: UInt32?, usbMic: UInt32? = nil) {
        current = defaultInput
        self.codexMic = codexMic
        self.usbMic = usbMic
    }

    func defaultInputDevice() throws -> UInt32 { current }
    func deviceID(uid: String) throws -> UInt32? {
        XCTAssertEqual(uid, CodexMicRouteManager.deviceUID)
        return codexMic
    }
    func deviceID(named: String) throws -> UInt32? {
        XCTAssertEqual(named, CodexMicRouteManager.usbMicrophoneName)
        return usbMic
    }
    func setDefaultInputDevice(_ id: UInt32) throws {
        current = id
        setCalls.append(id)
    }
}
