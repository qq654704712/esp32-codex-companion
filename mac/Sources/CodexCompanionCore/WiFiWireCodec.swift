import CryptoKit
import Foundation

public enum WiFiWireCodecError: Error, Equatable, Sendable {
    case invalidKeyLength
    case invalidSessionNonce
    case invalidNonceLength
    case invalidFrame
    case unsupportedVersion
    case invalidFrameKind
    case invalidPayloadLength
    case authenticationFailed
    case replayedSequence
}

public struct WiFiSessionKeys: Equatable, Sendable {
    public let controlKey: Data
    public let audioKey: Data
}

public enum SessionKeyDeriver {
    public static let pairingSecretByteCount = 32
    public static let sessionNonceByteCount = 32

    public static func derive(pairingSecret: Data, sessionNonce: Data) throws -> WiFiSessionKeys {
        guard pairingSecret.count == pairingSecretByteCount else {
            throw WiFiWireCodecError.invalidKeyLength
        }
        guard sessionNonce.count == sessionNonceByteCount else {
            throw WiFiWireCodecError.invalidSessionNonce
        }
        let input = SymmetricKey(data: pairingSecret)
        return WiFiSessionKeys(
            controlKey: deriveKey(input: input, salt: sessionNonce, label: "codex-control-v2"),
            audioKey: deriveKey(input: input, salt: sessionNonce, label: "codex-audio-v2")
        )
    }

    private static func deriveKey(input: SymmetricKey, salt: Data, label: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: salt,
            info: Data(label.utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

public struct WiFiControlEnvelope: Equatable, Sendable {
    public let sessionID: UInt64
    public let sequence: UInt32
    public let timestampMs: UInt64
    public let payload: Data

    public init(sessionID: UInt64, sequence: UInt32, timestampMs: UInt64, payload: Data) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestampMs = timestampMs
        self.payload = payload
    }
}

public struct WiFiAudioFrame: Equatable, Sendable {
    public static let sampleCount = 320
    public static let pcm16ByteCount = sampleCount * MemoryLayout<Int16>.size

    public let sessionID: UInt64
    public let sequence: UInt32
    public let timestampMs: UInt64
    public let pcm16LE: Data

    public init(sessionID: UInt64, sequence: UInt32, timestampMs: UInt64, pcm16LE: Data) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestampMs = timestampMs
        self.pcm16LE = pcm16LE
    }
}

public struct WiFiReplayWindow: Sendable {
    private var sessionID: UInt64?
    private var highestSequence: UInt32?
    private var seen: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func accept(sequence: UInt32, sessionID: UInt64) throws -> Bool {
        guard self.sessionID == sessionID else {
            self.sessionID = sessionID
            highestSequence = sequence
            seen = 1
            return true
        }
        guard let highestSequence else {
            self.highestSequence = sequence
            seen = 1
            return true
        }
        if sequence > highestSequence {
            let shift = sequence &- highestSequence
            seen = shift >= 64 ? 1 : (seen << UInt64(shift)) | 1
            self.highestSequence = sequence
            return true
        }
        let distance = highestSequence &- sequence
        guard distance < 64, (seen & (UInt64(1) << UInt64(distance))) == 0 else {
            throw WiFiWireCodecError.replayedSequence
        }
        seen |= UInt64(1) << UInt64(distance)
        return true
    }

    public mutating func reset() {
        sessionID = nil
        highestSequence = nil
        seen = 0
    }
}

public enum WiFiWireCodec {
    public static let version: UInt8 = 2
    public static let headerByteCount = 42
    public static let nonceByteCount = 12
    public static let tagByteCount = 16
    public static let maximumPayloadByteCount = 768

    private enum Kind: UInt8 { case control = 1, audio = 2 }

    public static func nonce(sessionID: UInt64, sequence: UInt32) -> Data {
        var value = Data()
        append(sessionID, to: &value)
        append(sequence, to: &value)
        return value
    }

    public static func encodeControl(
        _ envelope: WiFiControlEnvelope,
        key: Data,
        nonce: Data? = nil
    ) throws -> Data {
        try encode(
            kind: .control,
            sessionID: envelope.sessionID,
            sequence: envelope.sequence,
            timestampMs: envelope.timestampMs,
            payload: envelope.payload,
            key: key,
            nonce: nonce
        )
    }

    public static func decodeControl(_ packet: Data, key: Data) throws -> WiFiControlEnvelope {
        let frame = try decode(packet, expectedKind: .control, key: key)
        return WiFiControlEnvelope(
            sessionID: frame.sessionID,
            sequence: frame.sequence,
            timestampMs: frame.timestampMs,
            payload: frame.payload
        )
    }

    public static func encodeAudio(_ frame: WiFiAudioFrame, key: Data, nonce: Data? = nil) throws -> Data {
        guard frame.pcm16LE.count == WiFiAudioFrame.pcm16ByteCount else {
            throw WiFiWireCodecError.invalidPayloadLength
        }
        return try encode(
            kind: .audio,
            sessionID: frame.sessionID,
            sequence: frame.sequence,
            timestampMs: frame.timestampMs,
            payload: frame.pcm16LE,
            key: key,
            nonce: nonce
        )
    }

    public static func decodeAudio(_ packet: Data, key: Data) throws -> WiFiAudioFrame {
        let frame = try decode(packet, expectedKind: .audio, key: key)
        guard frame.payload.count == WiFiAudioFrame.pcm16ByteCount else {
            throw WiFiWireCodecError.invalidPayloadLength
        }
        return WiFiAudioFrame(
            sessionID: frame.sessionID,
            sequence: frame.sequence,
            timestampMs: frame.timestampMs,
            pcm16LE: frame.payload
        )
    }

    private static func encode(
        kind: Kind,
        sessionID: UInt64,
        sequence: UInt32,
        timestampMs: UInt64,
        payload: Data,
        key: Data,
        nonce explicitNonce: Data?
    ) throws -> Data {
        guard key.count == 32 else { throw WiFiWireCodecError.invalidKeyLength }
        guard payload.count <= maximumPayloadByteCount, payload.count <= Int(UInt16.max) else {
            throw WiFiWireCodecError.invalidPayloadLength
        }
        let nonce = explicitNonce ?? nonce(sessionID: sessionID, sequence: sequence)
        guard nonce.count == nonceByteCount else { throw WiFiWireCodecError.invalidNonceLength }
        var header = Data("CCW2".utf8)
        header.append(version)
        header.append(kind.rawValue)
        header.append(0)
        header.append(UInt8(headerByteCount))
        append(sessionID, to: &header)
        append(sequence, to: &header)
        append(timestampMs, to: &header)
        append(UInt16(payload.count), to: &header)
        header.append(nonce)
        let sealed = try ChaChaPoly.seal(
            payload,
            using: SymmetricKey(data: key),
            nonce: try ChaChaPoly.Nonce(data: nonce),
            authenticating: header
        )
        return header + sealed.ciphertext + sealed.tag
    }

    private static func decode(_ packet: Data, expectedKind: Kind, key: Data) throws -> (sessionID: UInt64, sequence: UInt32, timestampMs: UInt64, payload: Data) {
        guard key.count == 32 else { throw WiFiWireCodecError.invalidKeyLength }
        guard packet.count >= headerByteCount + tagByteCount else { throw WiFiWireCodecError.invalidFrame }
        let header = packet.prefix(headerByteCount)
        guard header.prefix(4) == Data("CCW2".utf8), header[4] == version else {
            throw WiFiWireCodecError.unsupportedVersion
        }
        guard header[5] == expectedKind.rawValue, header[6] == 0, header[7] == UInt8(headerByteCount) else {
            throw WiFiWireCodecError.invalidFrameKind
        }
        let sessionID = readUInt64(header, offset: 8)
        let sequence = readUInt32(header, offset: 16)
        let timestampMs = readUInt64(header, offset: 20)
        let payloadLength = Int(readUInt16(header, offset: 28))
        guard payloadLength <= maximumPayloadByteCount, packet.count == headerByteCount + payloadLength + tagByteCount else {
            throw WiFiWireCodecError.invalidPayloadLength
        }
        let nonce = Data(header[30..<42])
        let encryptedStart = headerByteCount
        let ciphertext = packet[encryptedStart..<(encryptedStart + payloadLength)]
        let tag = packet.suffix(tagByteCount)
        do {
            let sealed = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let payload = try ChaChaPoly.open(sealed, using: SymmetricKey(data: key), authenticating: header)
            return (sessionID, sequence, timestampMs, payload)
        } catch {
            throw WiFiWireCodecError.authenticationFailed
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data.SubSequence, offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) << 8 | UInt16(data[data.startIndex + offset + 1])
    }

    private static func readUInt32(_ data: Data.SubSequence, offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(data[data.startIndex + offset + $1]) }
    }

    private static func readUInt64(_ data: Data.SubSequence, offset: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(data[data.startIndex + offset + $1]) }
    }
}
