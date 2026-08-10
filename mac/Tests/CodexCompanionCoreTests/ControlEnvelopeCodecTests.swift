import XCTest
@testable import CodexCompanionCore

final class ControlEnvelopeCodecTests: XCTestCase {
    private let key = Data((0..<32).map(UInt8.init))

    func testSignedEnvelopeRoundTrips() throws {
        let envelope = ControlEnvelope(
            version: 1,
            sequence: 42,
            messageType: .pttDown,
            timestampMs: 1_234_567,
            payload: Data([0xA1, 0x00, 0xF5])
        )

        let encoded = try ControlEnvelopeCodec.encode(envelope, key: key)
        let decoded = try ControlEnvelopeCodec.decode(encoded, key: key)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(encoded.suffix(16).count, 16)
        XCTAssertEqual(
            encoded.hexString,
            "a6000101182a0207031a0012d6870443a100f505507ff7df989d9bd1eee0e46f355d6b1610"
        )
    }

    func testTamperedEnvelopeIsRejected() throws {
        let envelope = ControlEnvelope(
            version: 1,
            sequence: 9,
            messageType: .heartbeat,
            timestampMs: 44,
            payload: Data([0x01])
        )
        var encoded = try ControlEnvelopeCodec.encode(envelope, key: key)
        encoded[encoded.index(before: encoded.endIndex)] ^= 0x01

        XCTAssertThrowsError(try ControlEnvelopeCodec.decode(encoded, key: key)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .authenticationFailed)
        }
    }

    func testSequenceGuardRejectsReplay() throws {
        var guardState = SequenceGuard()

        XCTAssertNoThrow(try guardState.accept(10))
        XCTAssertThrowsError(try guardState.accept(10)) { error in
            XCTAssertEqual(error as? ControlProtocolError, .replayedSequence)
        }
        XCTAssertNoThrow(try guardState.accept(11))
    }

    func testSequenceGuardCanStartANewEncryptedConnectionSession() throws {
        var guardState = SequenceGuard()
        try guardState.accept(400)
        guardState.reset()
        XCTAssertNoThrow(try guardState.accept(1))
    }

    func testPeerLivenessExpiresAfterSixSecondsWithoutAuthenticatedInput() {
        var liveness = PeerLiveness(timeout: 6)
        liveness.markAuthenticatedInput(at: 100)
        XCTAssertFalse(liveness.isExpired(at: 106))
        XCTAssertTrue(liveness.isExpired(at: 106.001))
        liveness.reset()
        XCTAssertFalse(liveness.isExpired(at: 1_000))
    }

    func testUSBVoiceSessionDoesNotDependOnWirelessLiveness() {
        XCTAssertFalse(VoiceSessionSource.usb.requiresPeerLiveness)
        XCTAssertFalse(VoiceSessionSource.usb.isAffected(byLossOf: .ble))
        XCTAssertFalse(VoiceSessionSource.usb.isAffected(byLossOf: .wifi))
    }

    func testWirelessVoiceSessionOnlyDependsOnItsOwnTransport() {
        XCTAssertTrue(VoiceSessionSource.ble.requiresPeerLiveness)
        XCTAssertTrue(VoiceSessionSource.ble.isAffected(byLossOf: .ble))
        XCTAssertFalse(VoiceSessionSource.ble.isAffected(byLossOf: .wifi))
        XCTAssertTrue(VoiceSessionSource.wifi.isAffected(byLossOf: .wifi))
        XCTAssertFalse(VoiceSessionSource.wifi.isAffected(byLossOf: .ble))
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
