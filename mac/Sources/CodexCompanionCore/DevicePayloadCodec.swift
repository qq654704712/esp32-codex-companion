import Foundation

public enum DevicePayloadCodecError: Error, Equatable {
    case invalidEncoding
    case invalidQuota
    case unsupportedState
}

public struct DeviceQuotaPayload: Equatable, Sendable {
    public let fiveHour: UInt8?
    public let week: UInt8?
}

public enum DevicePayloadCodec {
    public static func heartbeat(quotaFresh: Bool) -> Data {
        Data([0xA1, 0x00, quotaFresh ? 0xF5 : 0xF4])
    }

    public static func state(_ state: DeviceState) throws -> Data {
        guard let identifier = state.identifier else {
            throw DevicePayloadCodecError.unsupportedState
        }
        return Data([0xA1, 0x00, identifier])
    }

    public static func decodeState(_ data: Data) throws -> DeviceState {
        guard data.count == 3, data[0] == 0xA1, data[1] == 0x00,
              let state = DeviceState(identifier: data[2]) else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        return state
    }

    public static func quota(fiveHour: UInt8?, week: UInt8?) throws -> Data {
        guard fiveHour.map({ $0 <= 100 }) ?? true,
              week.map({ $0 <= 100 }) ?? true else {
            throw DevicePayloadCodecError.invalidQuota
        }
        var result = Data([0xA2, 0x00])
        appendUnsigned(fiveHour ?? 255, to: &result)
        result.append(0x01)
        appendUnsigned(week ?? 255, to: &result)
        return result
    }

    public static func decodeQuota(_ data: Data) throws -> DeviceQuotaPayload {
        var index = 0
        guard readByte(data, index: &index) == 0xA2,
              readByte(data, index: &index) == 0x00,
              let five = readUnsigned(data, index: &index),
              readByte(data, index: &index) == 0x01,
              let week = readUnsigned(data, index: &index),
              index == data.count,
              five <= 255, week <= 255,
              five <= 100 || five == 255,
              week <= 100 || week == 255 else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        return DeviceQuotaPayload(
            fiveHour: five == 255 ? nil : UInt8(five),
            week: week == 255 ? nil : UInt8(week)
        )
    }

    private static func appendUnsigned(_ value: UInt8, to data: inout Data) {
        if value <= 23 { data.append(value) }
        else { data.append(contentsOf: [0x18, value]) }
    }

    private static func readByte(_ data: Data, index: inout Int) -> UInt8? {
        guard index < data.count else { return nil }
        defer { index += 1 }
        return data[index]
    }

    private static func readUnsigned(_ data: Data, index: inout Int) -> UInt64? {
        guard let initial = readByte(data, index: &index), initial >> 5 == 0 else { return nil }
        let value = initial & 0x1F
        if value <= 23 { return UInt64(value) }
        guard value == 24, let byte = readByte(data, index: &index) else { return nil }
        return UInt64(byte)
    }
}

private extension DeviceState {
    var identifier: UInt8? {
        switch self {
        case .disconnected: 0
        case .idle: 1
        case .sessionStarting: 2
        case .working: 3
        case .completed: 4
        case .error: 5
        case .approvalRequired: 6
        case .inputRequired: 7
        case .confirmationRequired: 8
        case .listening: 9
        case .voiceError: 10
        case .writing: 11
        case .running: 12
        }
    }

    init?(identifier: UInt8) {
        switch identifier {
        case 0: self = .disconnected
        case 1: self = .idle
        case 2: self = .sessionStarting
        case 3: self = .working
        case 4: self = .completed
        case 5: self = .error
        case 6: self = .approvalRequired
        case 7: self = .inputRequired
        case 8: self = .confirmationRequired
        case 9: self = .listening
        case 10: self = .voiceError
        case 11: self = .writing
        case 12: self = .running
        default: return nil
        }
    }
}
