import XCTest
@testable import CodexCompanionCore

final class WiFiSessionHandshakeTests: XCTestCase {
    private let secret = Data(repeating: 0x51, count: 32)

    func testAuthenticatedHandshakeRoundTripsAndDerivesSharedSessionNonce() throws {
        let device = try WiFiSessionHandshake(role: .device, nonce: Data(repeating: 0x11, count: 32))
        let host = try WiFiSessionHandshake(role: .host, nonce: Data(repeating: 0x22, count: 32))

        XCTAssertEqual(try WiFiSessionHandshake.decode(device.encode(pairingSecret: secret), pairingSecret: secret), device)
        XCTAssertEqual(try WiFiSessionHandshake.decode(host.encode(pairingSecret: secret), pairingSecret: secret), host)
        XCTAssertEqual(
            try WiFiSessionHandshake.sessionNonce(device: device, host: host),
            Data(SHA256Digest.hex("937eec12d3c7e4e531129ba5fae2a03f49e6c844e6247e6f349fc1a518a2fa19"))
        )
    }

    func testTamperedHandshakeCannotAuthenticate() throws {
        let handshake = try WiFiSessionHandshake(role: .device, nonce: Data(repeating: 0x11, count: 32))
        var encoded = try handshake.encode(pairingSecret: secret)
        encoded[8] ^= 0x01
        XCTAssertThrowsError(try WiFiSessionHandshake.decode(encoded, pairingSecret: secret)) {
            XCTAssertEqual($0 as? WiFiWireCodecError, .authenticationFailed)
        }
    }
}

private enum SHA256Digest {
    static func hex(_ value: String) -> [UInt8] {
        stride(from: 0, to: value.count, by: 2).map {
            UInt8(value[value.index(value.startIndex, offsetBy: $0)...value.index(value.startIndex, offsetBy: $0 + 1)], radix: 16)!
        }
    }
}
