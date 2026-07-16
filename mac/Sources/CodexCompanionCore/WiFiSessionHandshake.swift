import CryptoKit
import Foundation

/// Authenticated preface for a Wi-Fi TCP session. It is deliberately small
/// and contains no credentials: both peers already hold the 32-byte recovery
/// pairing secret. Each side contributes fresh entropy; their SHA-256 digest
/// is the HKDF salt used by `SessionKeyDeriver`.
public struct WiFiSessionHandshake: Equatable, Sendable {
    public enum Role: UInt8, Sendable { case device = 1, host = 2 }

    public static let magic = Data("CCH2".utf8)
    public static let version: UInt8 = 2
    public static let nonceByteCount = 32
    public static let tagByteCount = 16
    public static let encodedByteCount = 4 + 1 + 1 + nonceByteCount + tagByteCount

    public let role: Role
    public let nonce: Data

    public init(role: Role, nonce: Data) throws {
        guard nonce.count == Self.nonceByteCount else { throw WiFiWireCodecError.invalidSessionNonce }
        self.role = role
        self.nonce = nonce
    }

    public func encode(pairingSecret: Data) throws -> Data {
        guard pairingSecret.count == SessionKeyDeriver.pairingSecretByteCount else {
            throw WiFiWireCodecError.invalidKeyLength
        }
        var body = Self.magic
        body.append(Self.version)
        body.append(role.rawValue)
        body.append(nonce)
        let tag = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: pairingSecret))
        body.append(contentsOf: tag.prefix(Self.tagByteCount))
        return body
    }

    public static func decode(_ data: Data, pairingSecret: Data) throws -> WiFiSessionHandshake {
        guard pairingSecret.count == SessionKeyDeriver.pairingSecretByteCount else {
            throw WiFiWireCodecError.invalidKeyLength
        }
        guard data.count == encodedByteCount, data.prefix(4) == magic, data[4] == version,
              let role = Role(rawValue: data[5]) else {
            throw WiFiWireCodecError.invalidFrame
        }
        let body = data.prefix(encodedByteCount - tagByteCount)
        let tag = Data(data.suffix(tagByteCount))
        let expected = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: pairingSecret))
        guard tag == Data(expected.prefix(tagByteCount)) else {
            throw WiFiWireCodecError.authenticationFailed
        }
        return try WiFiSessionHandshake(role: role, nonce: Data(data[6..<(6 + nonceByteCount)]))
    }

    public static func sessionNonce(device: WiFiSessionHandshake, host: WiFiSessionHandshake) throws -> Data {
        guard device.role == .device, host.role == .host else {
            throw WiFiWireCodecError.invalidFrame
        }
        var material = Data("codex-wifi-session-v2".utf8)
        material.append(device.nonce)
        material.append(host.nonce)
        return Data(SHA256.hash(data: material))
    }

    /// Both peers derive this from the authenticated transcript, so it never
    /// needs a separate unencrypted field on the wire.
    public static func sessionID(device: WiFiSessionHandshake, host: WiFiSessionHandshake) throws -> UInt64 {
        let nonce = try sessionNonce(device: device, host: host)
        return nonce.prefix(MemoryLayout<UInt64>.size).reduce(0) { value, byte in
            (value << 8) | UInt64(byte)
        }
    }
}
