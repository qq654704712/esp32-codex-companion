#if os(macOS)
import Foundation

public struct CompanionHostIdentity: Equatable, Sendable {
    public let id: String
    public let publicKeyFingerprint: String

    public init(id: String, publicKeyFingerprint: String) {
        self.id = id
        self.publicKeyFingerprint = publicKeyFingerprint
    }

    public static let test = CompanionHostIdentity(id: "test-host", publicKeyFingerprint: "test-fingerprint")
}

#endif
