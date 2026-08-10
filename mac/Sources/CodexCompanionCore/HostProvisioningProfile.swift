#if os(macOS)
import Foundation

public struct CompanionHostCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let usbAudio = Self(rawValue: 1 << 0)
    public static let usbControl = Self(rawValue: 1 << 1)
    public static let bleControl = Self(rawValue: 1 << 2)
    public static let bleAudio = Self(rawValue: 1 << 3)
    public static let wifiControl = Self(rawValue: 1 << 4)
    public static let wifiAudio = Self(rawValue: 1 << 5)

    public static let macCompanion: Self = [
        .usbAudio, .usbControl, .bleControl, .bleAudio,
        .wifiControl, .wifiAudio,
    ]
}

public struct HostProvisioningProfile: Equatable, Sendable {
    public static let maximumHostIDBytes = 48
    public static let maximumDisplayNameBytes = 64

    public let hostID: String
    public let displayName: String
    public let capabilities: CompanionHostCapabilities
    public let pairingSecret: Data

    public init(
        hostID: String,
        displayName: String,
        capabilities: CompanionHostCapabilities,
        pairingSecret: Data
    ) {
        self.hostID = hostID
        self.displayName = displayName
        self.capabilities = capabilities
        self.pairingSecret = pairingSecret
    }

    public func encode() throws -> Data {
        let hostIDBytes = Data(hostID.utf8)
        let displayNameBytes = Data(displayName.utf8)
        guard !hostIDBytes.isEmpty, hostIDBytes.count <= Self.maximumHostIDBytes,
              !displayNameBytes.isEmpty,
              displayNameBytes.count <= Self.maximumDisplayNameBytes,
              pairingSecret.count == 32 else {
            throw HostProvisioningError.invalidProfile
        }
        var packet = Data("CCP2".utf8)
        packet.append(1)
        packet.append(capabilities.rawValue)
        packet.append(UInt8(hostIDBytes.count))
        packet.append(UInt8(displayNameBytes.count))
        packet.append(pairingSecret)
        packet.append(hostIDBytes)
        packet.append(displayNameBytes)
        return packet
    }
}

public enum HostProvisioningError: Error, Equatable {
    case invalidProfile
}

/// Stable identity of this companion installation. It is intentionally not a
/// machine serial number: users can remove it and pair a different host without
/// exposing hardware identifiers to the device.
final class HostProvisioningIdentityStore {
    private let defaults: UserDefaults
    private let key = "companion.host-identity.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadOrCreateID() -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = "host-\(UUID().uuidString.lowercased())"
        defaults.set(created, forKey: key)
        return created
    }

    func safeDisplayName() -> String {
        let source = Host.current().localizedName ?? "Companion host"
        // The round device ships a compact static font. Transliterate dynamic
        // host labels to printable ASCII so arbitrary computer names never
        // reintroduce missing-glyph squares on the device.
        let latin = source.applyingTransform(.toLatin, reverse: false) ?? source
        let printable = latin.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value <= 0x7e }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((printable.isEmpty ? "Companion host" : printable).prefix(64))
    }
}
#endif
