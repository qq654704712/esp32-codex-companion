import Foundation

public struct DevicePromptPayload: Equatable, Sendable {
    public let id: UInt32
    public let options: [CodexPromptOption]

    public init(id: UInt32, options: [CodexPromptOption]) {
        self.id = id
        self.options = options
    }
}

public struct DeviceOptionSelection: Equatable, Sendable {
    public let promptID: UInt32
    public let optionIndex: UInt8

    public init(promptID: UInt32, optionIndex: UInt8) {
        self.promptID = promptID
        self.optionIndex = optionIndex
    }
}

public enum DevicePromptPayloadError: Error, Equatable {
    case invalidEncoding
    case payloadTooLarge
}

public enum DevicePromptPayloadCodec {
    public static func encode(_ prompt: DevicePromptPayload) throws -> Data {
        guard !prompt.options.isEmpty, prompt.options.count <= 8 else {
            throw DevicePromptPayloadError.payloadTooLarge
        }
        var data = Data([0xA2, 0x00])
        appendMajor(0, value: UInt64(prompt.id), to: &data)
        data.append(0x01)
        appendMajor(4, value: UInt64(prompt.options.count), to: &data)
        for option in prompt.options {
            guard option.id.utf8.count <= 64, option.title.utf8.count <= 80 else {
                throw DevicePromptPayloadError.payloadTooLarge
            }
            data.append(0xA3)
            data.append(0x00)
            appendText(option.id, to: &data)
            data.append(0x01)
            appendText(option.title, to: &data)
            data.append(0x02)
            data.append(option.requiresLongPress ? 0xF5 : 0xF4)
        }
        guard data.count <= 440 else { throw DevicePromptPayloadError.payloadTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> DevicePromptPayload {
        var reader = PromptCBORReader(data)
        guard try reader.byte() == 0xA2,
              try reader.unsigned() == 0 else { throw DevicePromptPayloadError.invalidEncoding }
        let id = try reader.unsigned()
        guard id <= UInt32.max,
              try reader.unsigned() == 1,
              let count = try reader.majorLength(expectedMajor: 4), count <= 8 else {
            throw DevicePromptPayloadError.invalidEncoding
        }
        var options: [CodexPromptOption] = []
        for _ in 0..<count {
            guard try reader.byte() == 0xA3,
                  try reader.unsigned() == 0 else { throw DevicePromptPayloadError.invalidEncoding }
            let identifier = try reader.text()
            guard try reader.unsigned() == 1 else { throw DevicePromptPayloadError.invalidEncoding }
            let title = try reader.text()
            guard try reader.unsigned() == 2 else { throw DevicePromptPayloadError.invalidEncoding }
            let bool = try reader.byte()
            guard bool == 0xF4 || bool == 0xF5 else { throw DevicePromptPayloadError.invalidEncoding }
            options.append(.init(id: identifier, title: title, requiresLongPress: bool == 0xF5))
        }
        guard reader.isAtEnd else { throw DevicePromptPayloadError.invalidEncoding }
        return DevicePromptPayload(id: UInt32(id), options: options)
    }

    public static func decodeSelection(_ data: Data) throws -> DeviceOptionSelection {
        var reader = PromptCBORReader(data)
        guard try reader.byte() == 0xA2,
              try reader.unsigned() == 0 else { throw DevicePromptPayloadError.invalidEncoding }
        let promptID = try reader.unsigned()
        guard promptID <= UInt32.max,
              try reader.unsigned() == 1 else { throw DevicePromptPayloadError.invalidEncoding }
        let option = try reader.unsigned()
        guard option <= UInt8.max, reader.isAtEnd else {
            throw DevicePromptPayloadError.invalidEncoding
        }
        return .init(promptID: UInt32(promptID), optionIndex: UInt8(option))
    }

    private static func appendText(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendMajor(3, value: UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendMajor(_ major: UInt8, value: UInt64, to data: inout Data) {
        if value <= 23 {
            data.append((major << 5) | UInt8(value))
        } else if value <= UInt8.max {
            data.append((major << 5) | 24)
            data.append(UInt8(value))
        } else if value <= UInt16.max {
            data.append((major << 5) | 25)
            data.append(UInt8(value >> 8))
            data.append(UInt8(value))
        } else {
            data.append((major << 5) | 26)
            for shift in stride(from: 24, through: 0, by: -8) {
                data.append(UInt8(value >> UInt64(shift)))
            }
        }
    }
}

private struct PromptCBORReader {
    let data: Data
    var index = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { index == data.count }

    mutating func byte() throws -> UInt8 {
        guard index < data.count else { throw DevicePromptPayloadError.invalidEncoding }
        defer { index += 1 }
        return data[index]
    }

    mutating func unsigned() throws -> UInt64 {
        guard let value = try majorLength(expectedMajor: 0) else {
            throw DevicePromptPayloadError.invalidEncoding
        }
        return UInt64(value)
    }

    mutating func text() throws -> String {
        guard let count = try majorLength(expectedMajor: 3),
              count <= data.count - index else { throw DevicePromptPayloadError.invalidEncoding }
        let end = index + count
        guard let value = String(data: data[index..<end], encoding: .utf8) else {
            throw DevicePromptPayloadError.invalidEncoding
        }
        index = end
        return value
    }

    mutating func majorLength(expectedMajor: UInt8) throws -> Int? {
        let initial = try byte()
        guard initial >> 5 == expectedMajor else { return nil }
        let extra = initial & 0x1F
        if extra <= 23 { return Int(extra) }
        let count: Int
        switch extra {
        case 24: count = 1
        case 25: count = 2
        case 26: count = 4
        default: return nil
        }
        var value: UInt64 = 0
        for _ in 0..<count { value = (value << 8) | UInt64(try byte()) }
        guard value <= Int.max else { return nil }
        return Int(value)
    }
}
