import CryptoKit
import XCTest
@testable import CodexCompanionCore

final class WiFiWireCodecTests: XCTestCase {
    private let pairingSecret = Data(repeating: 0x11, count: 32)
    private let sessionNonce = Data((0..<32).map(UInt8.init))

    func testAudioFrameRoundTripsWithAuthenticatedHeader() throws {
        let keys = try SessionKeyDeriver.derive(
            pairingSecret: pairingSecret,
            sessionNonce: sessionNonce
        )
        let payload = Data(repeating: 0x7F, count: WiFiAudioFrame.pcm16ByteCount)
        let packet = try WiFiWireCodec.encodeAudio(
            WiFiAudioFrame(
                sessionID: 42,
                sequence: 7,
                timestampMs: 1_234,
                pcm16LE: payload
            ),
            key: keys.audioKey,
            nonce: Data(repeating: 0xA5, count: WiFiWireCodec.nonceByteCount)
        )

        let decoded = try WiFiWireCodec.decodeAudio(packet, key: keys.audioKey)

        XCTAssertEqual(decoded.sessionID, 42)
        XCTAssertEqual(decoded.sequence, 7)
        XCTAssertEqual(decoded.timestampMs, 1_234)
        XCTAssertEqual(decoded.pcm16LE, payload)
    }

    func testTamperedPacketIsRejected() throws {
        let keys = try SessionKeyDeriver.derive(
            pairingSecret: pairingSecret,
            sessionNonce: sessionNonce
        )
        var packet = try WiFiWireCodec.encodeControl(
            WiFiControlEnvelope(sessionID: 42, sequence: 7, timestampMs: 1, payload: Data([1, 2, 3])),
            key: keys.controlKey,
            nonce: Data(repeating: 0x05, count: WiFiWireCodec.nonceByteCount)
        )
        packet[WiFiWireCodec.headerByteCount] ^= 0x01

        XCTAssertThrowsError(try WiFiWireCodec.decodeControl(packet, key: keys.controlKey)) {
            XCTAssertEqual($0 as? WiFiWireCodecError, .authenticationFailed)
        }
    }

    func testAudioFrameRejectsDuplicateSequenceWithinSession() throws {
        var guarder = WiFiReplayWindow()

        XCTAssertTrue(try guarder.accept(sequence: 7, sessionID: 42))
        XCTAssertThrowsError(try guarder.accept(sequence: 7, sessionID: 42)) {
            XCTAssertEqual($0 as? WiFiWireCodecError, .replayedSequence)
        }
        XCTAssertTrue(try guarder.accept(sequence: 7, sessionID: 43))
    }

    func testKeyLabelsProduceSeparateKeys() throws {
        let keys = try SessionKeyDeriver.derive(
            pairingSecret: pairingSecret,
            sessionNonce: sessionNonce
        )

        XCTAssertEqual(keys.controlKey.count, 32)
        XCTAssertEqual(keys.audioKey.count, 32)
        XCTAssertNotEqual(keys.controlKey, keys.audioKey)
    }

    func testKeyDerivationMatchesHKDFSHA256GoldenVector() throws {
        let keys = try SessionKeyDeriver.derive(
            pairingSecret: pairingSecret,
            sessionNonce: sessionNonce
        )

        XCTAssertEqual(keys.controlKey.hexString, "6cf2bba73d629c854fc2aa6b8f01a5582da3d1a29514aad314b086c6eca22385")
        XCTAssertEqual(keys.audioKey.hexString, "f9f1d8c379c54afd29a16ad2af70f82161eef74b5606cc4d75707e9932a69c28")
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
