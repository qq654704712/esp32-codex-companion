import CryptoKit
import Foundation

public enum ControlMessageType: UInt16, Codable, CaseIterable, Sendable {
    case hello = 1
    case heartbeat = 2
    case stateUpdate = 3
    case quotaUpdate = 4
    case promptOpen = 5
    case promptClose = 6
    case pttDown = 7
    case pttUp = 8
    case optionSelect = 9
    case longPressConfirm = 10
    case audioLevel = 11
    case ack = 12
    case error = 13
    case taskEvent = 14
    case submit = 15
    case weatherUpdate = 16
    case weatherConfig = 17
}

public struct ControlEnvelope: Equatable, Sendable {
    public let version: UInt8
    public let sequence: UInt32
    public let messageType: ControlMessageType
    public let timestampMs: UInt64
    public let payload: Data

    public init(
        version: UInt8,
        sequence: UInt32,
        messageType: ControlMessageType,
        timestampMs: UInt64,
        payload: Data
    ) {
        self.version = version
        self.sequence = sequence
        self.messageType = messageType
        self.timestampMs = timestampMs
        self.payload = payload
    }
}

public enum ControlProtocolError: Error, Equatable {
    case invalidEncoding
    case unsupportedVersion
    case unknownMessageType
    case authenticationFailed
    case replayedSequence
}

public struct SequenceGuard: Sendable {
    private var lastAccepted: UInt32?

    public init() {}

    public mutating func accept(_ sequence: UInt32) throws {
        if let lastAccepted, sequence <= lastAccepted {
            throw ControlProtocolError.replayedSequence
        }
        lastAccepted = sequence
    }

    public mutating func reset() {
        lastAccepted = nil
    }
}

public struct PeerLiveness: Sendable {
    public let timeout: TimeInterval
    private var lastAuthenticatedInput: TimeInterval?

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    public mutating func markAuthenticatedInput(at time: TimeInterval) {
        lastAuthenticatedInput = time
    }

    public func isExpired(at time: TimeInterval) -> Bool {
        guard let lastAuthenticatedInput else { return false }
        return time - lastAuthenticatedInput > timeout
    }

    public mutating func reset() {
        lastAuthenticatedInput = nil
    }
}

public enum ControlEnvelopeCodec {
    public static func encode(_ envelope: ControlEnvelope, key: Data) throws -> Data {
        guard envelope.version == 1 else {
            throw ControlProtocolError.unsupportedVersion
        }
        let unsigned = encodeUnsigned(envelope)
        let tag = authenticationTag(for: unsigned, key: key)
        var signed = unsigned
        signed[signed.startIndex] = 0xA6
        appendUnsigned(5, to: &signed)
        appendBytes(tag, to: &signed)
        return signed
    }

    public static func decode(_ data: Data, key: Data) throws -> ControlEnvelope {
        var reader = CBORReader(data: data)
        guard try reader.readByte() == 0xA6 else {
            throw ControlProtocolError.invalidEncoding
        }
        let version = try readKeyedUnsigned(key: 0, reader: &reader)
        let sequence = try readKeyedUnsigned(key: 1, reader: &reader)
        let rawType = try readKeyedUnsigned(key: 2, reader: &reader)
        let timestamp = try readKeyedUnsigned(key: 3, reader: &reader)
        try expectKey(4, reader: &reader)
        let payload = try reader.readBytes()
        try expectKey(5, reader: &reader)
        let suppliedTag = try reader.readBytes()
        guard suppliedTag.count == 16, reader.isAtEnd else {
            throw ControlProtocolError.invalidEncoding
        }
        guard version == 1 else {
            throw ControlProtocolError.unsupportedVersion
        }
        guard sequence <= UInt32.max,
              rawType <= UInt16.max,
              let messageType = ControlMessageType(rawValue: UInt16(rawType)) else {
            throw ControlProtocolError.unknownMessageType
        }
        let envelope = ControlEnvelope(
            version: UInt8(version),
            sequence: UInt32(sequence),
            messageType: messageType,
            timestampMs: timestamp,
            payload: payload
        )
        let expectedTag = authenticationTag(for: encodeUnsigned(envelope), key: key)
        guard constantTimeEqual(suppliedTag, expectedTag) else {
            throw ControlProtocolError.authenticationFailed
        }
        return envelope
    }

    private static func encodeUnsigned(_ envelope: ControlEnvelope) -> Data {
        var data = Data([0xA5])
        appendUnsigned(0, to: &data)
        appendUnsigned(UInt64(envelope.version), to: &data)
        appendUnsigned(1, to: &data)
        appendUnsigned(UInt64(envelope.sequence), to: &data)
        appendUnsigned(2, to: &data)
        appendUnsigned(UInt64(envelope.messageType.rawValue), to: &data)
        appendUnsigned(3, to: &data)
        appendUnsigned(envelope.timestampMs, to: &data)
        appendUnsigned(4, to: &data)
        appendBytes(envelope.payload, to: &data)
        return data
    }

    private static func authenticationTag(for data: Data, key: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(
            for: data,
            using: SymmetricKey(data: key)
        )
        return Data(code.prefix(16))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func expectKey(_ key: UInt64, reader: inout CBORReader) throws {
        guard try reader.readUnsigned() == key else {
            throw ControlProtocolError.invalidEncoding
        }
    }

    private static func readKeyedUnsigned(
        key: UInt64,
        reader: inout CBORReader
    ) throws -> UInt64 {
        try expectKey(key, reader: &reader)
        return try reader.readUnsigned()
    }

    private static func appendBytes(_ value: Data, to data: inout Data) {
        appendMajor(2, value: UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func appendUnsigned(_ value: UInt64, to data: inout Data) {
        appendMajor(0, value: value, to: &data)
    }

    private static func appendMajor(_ major: UInt8, value: UInt64, to data: inout Data) {
        let prefix = major << 5
        switch value {
        case 0...23:
            data.append(prefix | UInt8(value))
        case 24...UInt64(UInt8.max):
            data.append(prefix | 24)
            data.append(UInt8(value))
        case 256...UInt64(UInt16.max):
            data.append(prefix | 25)
            appendBigEndian(UInt16(value), to: &data)
        case 65_536...UInt64(UInt32.max):
            data.append(prefix | 26)
            appendBigEndian(UInt32(value), to: &data)
        default:
            data.append(prefix | 27)
            appendBigEndian(value, to: &data)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

private struct CBORReader {
    let data: Data
    var index: Data.Index

    init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    var isAtEnd: Bool { index == data.endIndex }

    mutating func readByte() throws -> UInt8 {
        guard index < data.endIndex else { throw ControlProtocolError.invalidEncoding }
        defer { index = data.index(after: index) }
        return data[index]
    }

    mutating func readUnsigned() throws -> UInt64 {
        let initial = try readByte()
        guard initial >> 5 == 0 else { throw ControlProtocolError.invalidEncoding }
        return try readLength(initial & 0x1F)
    }

    mutating func readBytes() throws -> Data {
        let initial = try readByte()
        guard initial >> 5 == 2 else { throw ControlProtocolError.invalidEncoding }
        let count = try readLength(initial & 0x1F)
        guard count <= UInt64(data.distance(from: index, to: data.endIndex)) else {
            throw ControlProtocolError.invalidEncoding
        }
        let end = data.index(index, offsetBy: Int(count))
        defer { index = end }
        return data[index..<end]
    }

    private mutating func readLength(_ additional: UInt8) throws -> UInt64 {
        switch additional {
        case 0...23:
            return UInt64(additional)
        case 24:
            return UInt64(try readByte())
        case 25:
            return UInt64(try readInteger(UInt16.self))
        case 26:
            return UInt64(try readInteger(UInt32.self))
        case 27:
            return try readInteger(UInt64.self)
        default:
            throw ControlProtocolError.invalidEncoding
        }
    }

    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let count = MemoryLayout<T>.size
        guard data.distance(from: index, to: data.endIndex) >= count else {
            throw ControlProtocolError.invalidEncoding
        }
        var value: T = 0
        for _ in 0..<count {
            value = (value << 8) | T(try readByte())
        }
        return value
    }
}
