import Foundation
import XCTest
@testable import CodexCompanionCore

final class DevicePromptPayloadCodecTests: XCTestCase {
    func testRoundTripPrompt() throws {
        let prompt = DevicePromptPayload(
            id: 77,
            options: [
                .init(id: "approval.allow_once", title: "允许一次", requiresLongPress: false),
                .init(id: "approval.allow_session", title: "本次会话允许", requiresLongPress: true),
            ]
        )
        XCTAssertEqual(try DevicePromptPayloadCodec.decode(try DevicePromptPayloadCodec.encode(prompt)), prompt)
    }

    func testSelection() throws {
        let payload = Data([0xA2, 0x00, 0x18, 0x4D, 0x01, 0x01])
        XCTAssertEqual(try DevicePromptPayloadCodec.decodeSelection(payload), .init(promptID: 77, optionIndex: 1))
    }
}
