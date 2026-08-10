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

public struct DeviceActivityPayload: Equatable, Sendable {
    public let state: DeviceState
    public let activeTasks: UInt8
    public let attentionTasks: UInt8
    public let recentCompletedTasks: UInt8

    public init(
        state: DeviceState,
        activeTasks: UInt8,
        attentionTasks: UInt8,
        recentCompletedTasks: UInt8
    ) {
        self.state = state
        self.activeTasks = activeTasks
        self.attentionTasks = attentionTasks
        self.recentCompletedTasks = recentCompletedTasks
    }
}

public struct DeviceWeatherPayload: Equatable, Sendable {
    public let city: String
    public let temperatureTenthsCelsius: Int16
    public let weatherCode: UInt8

    public init(city: String, temperatureTenthsCelsius: Int16, weatherCode: UInt8) {
        self.city = city
        self.temperatureTenthsCelsius = temperatureTenthsCelsius
        self.weatherCode = weatherCode
    }
}

public struct DeviceWeatherConfigurationPayload: Equatable, Sendable {
    public let enabled: Bool
    public let usesCelsius: Bool
    public let refreshMinutes: UInt8

    public init(enabled: Bool, usesCelsius: Bool, refreshMinutes: UInt8) {
        self.enabled = enabled
        self.usesCelsius = usesCelsius
        self.refreshMinutes = refreshMinutes
    }
}

public enum DevicePayloadCodec {
    public static func heartbeat(quotaFresh: Bool) -> Data {
        Data([0xA1, 0x00, quotaFresh ? 0xF5 : 0xF4])
    }

    public static func taskEvent(_ kind: CodexTaskEventKind) -> Data {
        Data([0xA1, 0x00, kind.rawValue])
    }

    public static func decodeTaskEvent(_ data: Data) throws -> CodexTaskEventKind {
        guard data.count == 3, data[0] == 0xA1, data[1] == 0x00,
              let kind = CodexTaskEventKind(rawValue: data[2]) else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        return kind
    }

    public static func state(_ state: DeviceState) throws -> Data {
        guard let identifier = state.identifier else {
            throw DevicePayloadCodecError.unsupportedState
        }
        return Data([0xA1, 0x00, identifier])
    }

    /// Extended state payload. Key 0 preserves the v1 state identifier while
    /// keys 1...3 carry a bounded multi-conversation summary for newer devices.
    public static func activity(_ activity: DeviceActivityPayload) throws -> Data {
        guard let identifier = activity.state.identifier else {
            throw DevicePayloadCodecError.unsupportedState
        }
        var result = Data([0xA4, 0x00, identifier, 0x01])
        appendUnsigned(activity.activeTasks, to: &result)
        result.append(0x02)
        appendUnsigned(activity.attentionTasks, to: &result)
        result.append(0x03)
        appendUnsigned(activity.recentCompletedTasks, to: &result)
        return result
    }

    public static func decodeState(_ data: Data) throws -> DeviceState {
        guard data.count == 3, data[0] == 0xA1, data[1] == 0x00,
              let state = DeviceState(identifier: data[2]) else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        return state
    }

    public static func decodeActivity(_ data: Data) throws -> DeviceActivityPayload {
        if data.count == 3 {
            return DeviceActivityPayload(
                state: try decodeState(data),
                activeTasks: 0,
                attentionTasks: 0,
                recentCompletedTasks: 0
            )
        }
        var index = 0
        guard readByte(data, index: &index) == 0xA4,
              readByte(data, index: &index) == 0x00,
              let stateValue = readUnsigned(data, index: &index),
              stateValue <= UInt64(UInt8.max),
              let state = DeviceState(identifier: UInt8(stateValue)),
              readByte(data, index: &index) == 0x01,
              let active = readUnsigned(data, index: &index),
              readByte(data, index: &index) == 0x02,
              let attention = readUnsigned(data, index: &index),
              readByte(data, index: &index) == 0x03,
              let completed = readUnsigned(data, index: &index),
              index == data.count,
              active <= 255, attention <= 255, completed <= 255 else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        return DeviceActivityPayload(
            state: state,
            activeTasks: UInt8(active),
            attentionTasks: UInt8(attention),
            recentCompletedTasks: UInt8(completed)
        )
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

    public static func weather(_ payload: DeviceWeatherPayload) throws -> Data {
        let city = Data(payload.city.utf8)
        guard !city.isEmpty, city.count <= 48 else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        let temperature = UInt16(bitPattern: payload.temperatureTenthsCelsius)
        var result = Data([
            1, UInt8(temperature >> 8), UInt8(temperature & 0xFF),
            payload.weatherCode, UInt8(city.count),
        ])
        result.append(city)
        return result
    }

    public static func decodeWeather(_ data: Data) throws -> DeviceWeatherPayload {
        guard data.count >= 6, data[0] == 1 else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        let cityLength = Int(data[4])
        guard cityLength > 0, cityLength <= 48, data.count == 5 + cityLength,
              let city = String(data: data[5...], encoding: .utf8) else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        let raw = UInt16(data[1]) << 8 | UInt16(data[2])
        return DeviceWeatherPayload(
            city: city,
            temperatureTenthsCelsius: Int16(bitPattern: raw),
            weatherCode: data[3]
        )
    }

    public static func weatherConfiguration(
        _ payload: DeviceWeatherConfigurationPayload
    ) throws -> Data {
        guard [15, 30, 60].contains(payload.refreshMinutes) else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        return Data([
            1, payload.enabled ? 1 : 0, payload.usesCelsius ? 1 : 0,
            payload.refreshMinutes,
        ])
    }

    public static func decodeWeatherConfiguration(
        _ data: Data
    ) throws -> DeviceWeatherConfigurationPayload {
        guard data.count == 4, data[0] == 1, data[1] <= 1, data[2] <= 1,
              [15, 30, 60].contains(data[3]) else {
            throw DevicePayloadCodecError.invalidEncoding
        }
        return DeviceWeatherConfigurationPayload(
            enabled: data[1] == 1,
            usesCelsius: data[2] == 1,
            refreshMinutes: data[3]
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
