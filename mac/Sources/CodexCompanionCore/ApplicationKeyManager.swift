#if os(macOS)
import Foundation
import Security

public protocol ApplicationKeyStorage: AnyObject {
    func load() throws -> Data?
    func save(_ value: Data) throws
}

public enum ApplicationKeyError: Error, Equatable {
    case invalidLength
    case randomGeneration(OSStatus)
    case keychain(OSStatus)
}

/// Keychain calls are thread-safe; this wrapper retains immutable dependencies
/// after initialization and is used by CoreBluetooth's background queue.
public final class ApplicationKeyManager: @unchecked Sendable {
    private let storage: ApplicationKeyStorage
    private let generator: () throws -> Data

    public init(
        storage: ApplicationKeyStorage = KeychainApplicationKeyStorage(),
        generator: @escaping () throws -> Data = ApplicationKeyManager.generate
    ) {
        self.storage = storage
        self.generator = generator
    }

    public func loadOrCreate() throws -> Data {
        if let existing = try storage.load() {
            guard existing.count == 32 else { throw ApplicationKeyError.invalidLength }
            return existing
        }
        let created = try generator()
        guard created.count == 32 else { throw ApplicationKeyError.invalidLength }
        try storage.save(created)
        return created
    }

    public static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ApplicationKeyError.randomGeneration(status)
        }
        return Data(bytes)
    }
}

public final class KeychainApplicationKeyStorage: ApplicationKeyStorage {
    private let service = "com.codexcompanion.security"
    private let account = "ble-hmac-key-v1"

    public init() {}

    public func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ApplicationKeyError.keychain(status) }
        return result as? Data
    }

    public func save(_ value: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ApplicationKeyError.keychain(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif
