import Foundation

/// TCP is a byte stream, while CCW2 is a datagram format. This small outer
/// frame is only a transport boundary: the encrypted CCW2 length remains
/// authenticated inside its own header and must match after decryption.
public struct WiFiTCPFramer: Sendable {
    public static let prefixByteCount = 2
    public static let maximumPacketByteCount = WiFiWireCodec.headerByteCount +
        WiFiWireCodec.maximumPayloadByteCount + WiFiWireCodec.tagByteCount

    private var buffer = Data()

    public init() {}

    public static func encode(_ packet: Data) throws -> Data {
        guard !packet.isEmpty, packet.count <= maximumPacketByteCount,
              packet.count <= Int(UInt16.max) else {
            throw WiFiWireCodecError.invalidPayloadLength
        }
        var result = Data()
        var length = UInt16(packet.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(packet)
        return result
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var packets: [Data] = []
        while buffer.count >= Self.prefixByteCount {
            let length = Int(UInt16(buffer[0]) << 8 | UInt16(buffer[1]))
            guard length > 0, length <= Self.maximumPacketByteCount else {
                buffer.removeAll(keepingCapacity: false)
                throw WiFiWireCodecError.invalidPayloadLength
            }
            guard buffer.count >= Self.prefixByteCount + length else { break }
            packets.append(Data(buffer[Self.prefixByteCount..<(Self.prefixByteCount + length)]))
            buffer.removeSubrange(0..<(Self.prefixByteCount + length))
        }
        return packets
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}
