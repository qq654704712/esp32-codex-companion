#if os(macOS)
import Darwin
import Foundation

/// Provides a copyable IPv4 fallback for the device setup portal. This is not
/// an authentication identifier; the existing CCH2 pairing handshake remains
/// mandatory after the device connects to this address.
public enum CompanionLANEndpoint {
    public static func preferredIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var candidates: [(priority: Int, address: String)] = []
        for pointer in sequence(first: interfaces, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            guard let rawAddress = item.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var socketAddress = UnsafeRawPointer(rawAddress)
                .assumingMemoryBound(to: sockaddr_in.self).pointee
            var storage = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &socketAddress.sin_addr, &storage,
                            socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let address = String(
                bytes: storage.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                encoding: .utf8
            ) ?? ""
            // Prefer physical interfaces, then other active non-loopback
            // interfaces. VPN and link-local routes are less useful for an
            // ESP32 on the same ordinary Wi-Fi/Ethernet LAN.
            let name = String(cString: item.ifa_name)
            let priority: Int
            if name == "en0" { priority = 0 }
            else if name.hasPrefix("en") { priority = 1 }
            else if address.hasPrefix("169.254.") { priority = 3 }
            else { priority = 2 }
            candidates.append((priority, address))
        }
        return candidates.sorted {
            $0.priority == $1.priority ? $0.address < $1.address : $0.priority < $1.priority
        }.first?.address
    }
}
#endif
