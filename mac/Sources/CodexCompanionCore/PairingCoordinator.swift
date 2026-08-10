#if os(macOS)
import Foundation

/// A user-visible candidate discovered over mDNS or BLE. Discovery is only a
/// hint; the coordinator will not create a usable record until both parties
/// confirm the SAS.
public struct PairingCandidate: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let endpoint: String?

    public init(id: String, displayName: String, endpoint: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
    }
}

public struct PairingRecord: Equatable, Sendable {
    public let hostID: String
    public let displayName: String
    public let endpoint: String?
    public let pairingSecret: Data
    public let peerPublicKey: Data

    public init(hostID: String, displayName: String, endpoint: String?, pairingSecret: Data, peerPublicKey: Data) {
        self.hostID = hostID
        self.displayName = displayName
        self.endpoint = endpoint
        self.pairingSecret = pairingSecret
        self.peerPublicKey = peerPublicKey
    }
}

public protocol PairingRecordStore: AnyObject {
    func save(_ record: PairingRecord) throws
    func remove(hostID: String) throws
}

public enum PairingCoordinatorError: Error, Equatable {
    case alreadyInProgress
    case noPairingInProgress
    case invalidSAS
    case peerRejected
    case expired
    case invalidSecret
}

public enum PairingPhase: Equatable, Sendable {
    case idle
    case awaitingConfirmation(candidate: PairingCandidate, sas: String, expiresAt: Date)
    case paired(PairingRecord)
    case failed(PairingCoordinatorError)
}

/// Coordinates the human-presence half of recovery pairing. Cryptographic
/// exchange is deliberately supplied by the transport layer; this type owns
/// only lifecycle, SAS validation and the atomic persistence boundary.
public final class PairingCoordinator: @unchecked Sendable {
    public private(set) var phase: PairingPhase = .idle

    private let store: PairingRecordStore
    private let now: () -> Date
    private let sasProvider: (PairingCandidate) -> String
    private var pendingSecret: Data?
    private var pendingPeerKey: Data?

    public init(
        store: PairingRecordStore,
        now: @escaping () -> Date = Date.init,
        sasProvider: @escaping (PairingCandidate) -> String = { _ in
            String(format: "%06d", Int.random(in: 0...999_999))
        }
    ) {
        self.store = store
        self.now = now
        self.sasProvider = sasProvider
    }

    public func beginRecovery(
        candidate: PairingCandidate,
        pairingSecret: Data,
        peerPublicKey: Data,
        timeout: TimeInterval = 90
    ) throws {
        guard case .idle = phase else { throw PairingCoordinatorError.alreadyInProgress }
        guard pairingSecret.count == 32, !peerPublicKey.isEmpty else {
            throw PairingCoordinatorError.invalidSecret
        }
        let sas = sasProvider(candidate)
        guard sas.count == 6, sas.allSatisfy(\.isNumber) else {
            throw PairingCoordinatorError.invalidSAS
        }
        pendingSecret = pairingSecret
        pendingPeerKey = peerPublicKey
        phase = .awaitingConfirmation(candidate: candidate, sas: sas, expiresAt: now().addingTimeInterval(timeout))
    }

    /// Persists only after the local SAS check and the peer's encrypted
    /// confirmation have both succeeded. The caller must pass the same SAS
    /// shown by the peer; transport authentication is outside this type.
    public func confirm(sas: String, peerAccepted: Bool = true) throws {
        guard case let .awaitingConfirmation(candidate, expected, expiresAt) = phase else {
            throw PairingCoordinatorError.noPairingInProgress
        }
        guard now() <= expiresAt else {
            clearPending()
            phase = .failed(.expired)
            throw PairingCoordinatorError.expired
        }
        guard sas == expected else {
            clearPending()
            phase = .failed(.invalidSAS)
            throw PairingCoordinatorError.invalidSAS
        }
        guard peerAccepted else {
            clearPending()
            phase = .failed(.peerRejected)
            throw PairingCoordinatorError.peerRejected
        }
        guard let secret = pendingSecret, let peerKey = pendingPeerKey else {
            clearPending()
            phase = .failed(.invalidSecret)
            throw PairingCoordinatorError.invalidSecret
        }
        let record = PairingRecord(hostID: candidate.id, displayName: candidate.displayName,
                                   endpoint: candidate.endpoint, pairingSecret: secret, peerPublicKey: peerKey)
        do {
            try store.save(record)
        } catch {
            clearPending()
            phase = .failed(.invalidSecret)
            throw error
        }
        clearPending()
        phase = .paired(record)
    }

    public func cancel() {
        clearPending()
        phase = .idle
    }

    public func unpair(hostID: String) throws {
        try store.remove(hostID: hostID)
        if case let .paired(record) = phase, record.hostID == hostID { phase = .idle }
    }

    private func clearPending() {
        pendingSecret = nil
        pendingPeerKey = nil
    }
}
#endif
