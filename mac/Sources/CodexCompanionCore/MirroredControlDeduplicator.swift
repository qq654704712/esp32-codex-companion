import Foundation

/// BLE and Wi-Fi intentionally carry the exact same signed ControlEnvelope.
/// Their replay guards stay independent for reconnect recovery; this bounded
/// cache prevents the mirrored copy from performing an action twice.
public struct MirroredControlDeduplicator: Sendable {
    private struct Entry: Sendable {
        let packet: Data
        let receivedAt: TimeInterval
    }

    private let retention: TimeInterval
    private let capacity: Int
    private var entries: [Entry] = []

    public init(retention: TimeInterval = 30, capacity: Int = 64) {
        self.retention = max(1, retention)
        self.capacity = max(1, capacity)
    }

    public mutating func accept(_ packet: Data, at time: TimeInterval) -> Bool {
        entries.removeAll { time - $0.receivedAt > retention }
        guard !entries.contains(where: { $0.packet == packet }) else { return false }
        entries.append(Entry(packet: packet, receivedAt: time))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return true
    }

    public mutating func reset() { entries.removeAll(keepingCapacity: true) }
}
