#if os(macOS)
import Network
import XCTest
@testable import CodexCompanionCore

final class WiFiControlServerIntegrationTests: XCTestCase {
    private let secret = Data(repeating: 0x73, count: SessionKeyDeriver.pairingSecretByteCount)

    func testLoopbackDeviceCompletesHandshakeAndDeliversEncryptedControl() throws {
        let pairingSecret = secret
        let port = UInt16(53_000 + (ProcessInfo.processInfo.processIdentifier % 1_000))
        let server = try WiFiControlServer(
            pairingSecret: pairingSecret,
            hostIdentity: .test,
            port: port
        )
        let listening = expectation(description: "listener ready")
        let received = expectation(description: "encrypted control delivered")
        let expectedPayload = Data([0xA1, 0x01, 0x02, 0x03])
        server.onStateChange = { state in
            if case .listening = state { listening.fulfill() }
        }
        server.onControlMessage = { payload in
            XCTAssertEqual(payload, expectedPayload)
            received.fulfill()
        }
        server.start()
        wait(for: [listening], timeout: 3)

        let device = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let connected = expectation(description: "loopback device connected")
        device.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        device.start(queue: .global(qos: .userInitiated))
        wait(for: [connected], timeout: 3)

        let handshake = try WiFiSessionHandshake(
            role: .device,
            nonce: Data(repeating: 0x31, count: WiFiSessionHandshake.nonceByteCount)
        )
        let sent = expectation(description: "device handshake sent")
        device.send(
            content: try handshake.encode(pairingSecret: pairingSecret),
            completion: .contentProcessed { error in
                XCTAssertNil(error)
                sent.fulfill()
            }
        )
        wait(for: [sent], timeout: 3)

        let hostResponse = expectation(description: "host handshake received")
        device.receive(
            minimumIncompleteLength: WiFiSessionHandshake.encodedByteCount,
            maximumLength: WiFiSessionHandshake.encodedByteCount
        ) { data, _, _, error in
            XCTAssertNil(error)
            do {
                let host = try WiFiSessionHandshake.decode(data ?? Data(), pairingSecret: pairingSecret)
                let nonce = try WiFiSessionHandshake.sessionNonce(device: handshake, host: host)
                let key = try SessionKeyDeriver.derive(pairingSecret: pairingSecret, sessionNonce: nonce).controlKey
                let packet = try WiFiWireCodec.encodeControl(
                    WiFiControlEnvelope(
                        sessionID: try WiFiSessionHandshake.sessionID(device: handshake, host: host),
                        sequence: 1,
                        timestampMs: 1,
                        payload: expectedPayload
                    ),
                    key: key
                )
                device.send(content: try WiFiTCPFramer.encode(packet), completion: .contentProcessed { error in
                    XCTAssertNil(error)
                })
            } catch {
                XCTFail("device-side protocol failure: \(error)")
            }
            hostResponse.fulfill()
        }
        wait(for: [hostResponse, received], timeout: 3)
        device.cancel()
        server.stop()
    }

    func testUDPDiscoveryReturnsHostMarker() throws {
        let port = UInt16(55_000 + (ProcessInfo.processInfo.processIdentifier % 500))
        let discoveryPort = port + 1
        let server = try WiFiControlServer(
            pairingSecret: secret,
            hostIdentity: .test,
            port: port,
            discoveryPort: discoveryPort
        )
        let listening = expectation(description: "TCP listener ready")
        server.onStateChange = { state in
            if case .listening = state { listening.fulfill() }
        }
        server.start()
        wait(for: [listening], timeout: 3)

        let probe = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: discoveryPort)!,
            using: .udp
        )
        let ready = expectation(description: "UDP probe ready")
        probe.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        probe.start(queue: .global(qos: .userInitiated))
        wait(for: [ready], timeout: 3)

        let reply = expectation(description: "discovery reply")
        probe.send(content: Data("CCDISC2".utf8), completion: .contentProcessed { error in
            XCTAssertNil(error)
        })
        probe.receiveMessage { data, _, _, error in
            XCTAssertNil(error)
            XCTAssertEqual(data, Data("CCHOST2".utf8))
            reply.fulfill()
        }
        wait(for: [reply], timeout: 3)
        probe.cancel()
        server.stop()
    }
}
#endif
