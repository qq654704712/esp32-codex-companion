#if os(macOS)
import Foundation
import XCTest
@testable import CodexCompanionCore

final class HostProvisioningProfileTests: XCTestCase {
    func testEncodesVersionedHostMetadataAndSecret() throws {
        let profile = HostProvisioningProfile(
            hostID: "host-1234",
            displayName: "Studio Mac",
            capabilities: .macCompanion,
            pairingSecret: Data(repeating: 0x5a, count: 32)
        )
        let packet = try profile.encode()
        XCTAssertEqual(String(data: packet.prefix(4), encoding: .utf8), "CCP2")
        XCTAssertEqual(packet[4], 1)
        XCTAssertEqual(packet[5], CompanionHostCapabilities.macCompanion.rawValue)
        XCTAssertEqual(packet[6], 9)
        XCTAssertEqual(packet[7], 10)
        XCTAssertEqual(packet[8..<40], Data(repeating: 0x5a, count: 32))
        XCTAssertEqual(String(data: packet[40..<49], encoding: .utf8), "host-1234")
        XCTAssertEqual(String(data: packet[49..<59], encoding: .utf8), "Studio Mac")
    }

    func testRejectsInvalidSecretLength() {
        let profile = HostProvisioningProfile(
            hostID: "host", displayName: "Mac", capabilities: .bleControl,
            pairingSecret: Data(repeating: 1, count: 31)
        )
        XCTAssertThrowsError(try profile.encode())
    }
}
#endif
