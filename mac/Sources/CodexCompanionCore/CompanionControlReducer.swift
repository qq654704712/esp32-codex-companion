import Foundation

public struct RevisionedDeviceState: Equatable, Sendable {
    public let state: DeviceState
    public let sessionID: String?
    public let turnID: String?
    public let revision: UInt64
    public let expiresAt: Date?
    public let actionID: UUID?
}

/// Serializes hook-derived state into monotonic snapshots. A device action is
/// valid only for the exact revision/action that created it; reconnects can
/// request the current snapshot but cannot resurrect a previous approval.
public struct CompanionControlReducer {
    private let now: () -> Date
    private var revision: UInt64 = 0
    private var current: RevisionedDeviceState?

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    @discardableResult
    public mutating func reduce(hook: CodexHookEvent) -> RevisionedDeviceState {
        revision &+= 1
        let approval = hook.state == .approvalRequired || hook.state == .confirmationRequired
        let snapshot = RevisionedDeviceState(
            state: hook.state,
            sessionID: hook.sessionID,
            turnID: hook.turnID,
            revision: revision,
            expiresAt: approval ? now().addingTimeInterval(30) : nil,
            actionID: approval ? UUID() : nil
        )
        current = snapshot
        return snapshot
    }

    public func currentSnapshot() -> RevisionedDeviceState? {
        guard let current, current.expiresAt.map({ $0 > now() }) ?? true else { return nil }
        return current
    }

    public func applyRemoteAcknowledgement(revision acknowledged: UInt64) -> RevisionedDeviceState? {
        guard let current = currentSnapshot(), acknowledged == current.revision else { return nil }
        return current
    }

    public func allowsAction(revision: UInt64, actionID: UUID) -> Bool {
        guard let current = currentSnapshot() else { return false }
        return current.revision == revision && current.actionID == actionID
    }
}
