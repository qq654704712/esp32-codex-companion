import Foundation

public enum BLEControlFramingError: Error, Equatable {
    case packetTooLarge
    case invalidFragment
    case outOfSequence
}

public enum BLEControlFramer {
    public static let gattPayloadLimit = 244
    public static let headerLength = 5
    public static let maximumPacketLength = 512
    private static let magic: UInt8 = 0xCC

    public static func fragment(_ packet: Data, frameID: UInt16) throws -> [Data] {
        guard packet.count <= maximumPacketLength else {
            throw BLEControlFramingError.packetTooLarge
        }
        let chunkSize = gattPayloadLimit - headerLength
        let count = max(1, (packet.count + chunkSize - 1) / chunkSize)
        guard count <= Int(UInt8.max) else { throw BLEControlFramingError.packetTooLarge }
        return (0..<count).map { index in
            let start = index * chunkSize
            let end = min(start + chunkSize, packet.count)
            var fragment = Data([
                magic, UInt8(frameID >> 8), UInt8(truncatingIfNeeded: frameID),
                UInt8(index), UInt8(count),
            ])
            if start < end { fragment.append(packet[start..<end]) }
            return fragment
        }
    }
}

public struct BLEControlReassembler: Sendable {
    private var frameID: UInt16?
    private var expectedIndex: UInt8 = 0
    private var fragmentCount: UInt8 = 0
    private var buffer = Data()

    public init() {}

    public mutating func accept(_ fragment: Data) throws -> Data? {
        guard fragment.count >= BLEControlFramer.headerLength,
              fragment[0] == 0xCC,
              fragment[4] > 0,
              fragment[3] < fragment[4] else {
            reset()
            throw BLEControlFramingError.invalidFragment
        }
        let incomingID = UInt16(fragment[1]) << 8 | UInt16(fragment[2])
        let index = fragment[3]
        let count = fragment[4]
        if index == 0 {
            frameID = incomingID
            expectedIndex = 0
            fragmentCount = count
            buffer.removeAll(keepingCapacity: true)
        }
        guard frameID == incomingID, fragmentCount == count, index == expectedIndex else {
            reset()
            throw BLEControlFramingError.outOfSequence
        }
        buffer.append(fragment.dropFirst(BLEControlFramer.headerLength))
        guard buffer.count <= BLEControlFramer.maximumPacketLength else {
            reset()
            throw BLEControlFramingError.packetTooLarge
        }
        expectedIndex &+= 1
        if expectedIndex == fragmentCount {
            let completed = buffer
            reset()
            return completed
        }
        return nil
    }

    private mutating func reset() {
        frameID = nil
        expectedIndex = 0
        fragmentCount = 0
        buffer.removeAll(keepingCapacity: true)
    }
}
