#if os(macOS)
import Foundation

/// Process-owned runtime boundary. The launch agent owns this object; windows
/// only observe its status and must never use their visibility as a shutdown
/// signal for BLE, PTT, hook draining, or audio routing.
@MainActor
public final class CompanionAgent {
    public enum Lifecycle: String, Codable, Equatable, Sendable {
        case stopped
        case starting
        case running
        case stopping
    }

    public struct StatusSnapshot: Equatable, Sendable {
        public let lifecycle: Lifecycle

        public init(lifecycle: Lifecycle) {
            self.lifecycle = lifecycle
        }
    }

    public struct Dependencies {
        let startTransport: () -> Void
        let stopTransport: () -> Void
        let runtimeStatus: () -> CompanionRuntimeStatus?

        public init(
            startTransport: @escaping () -> Void,
            stopTransport: @escaping () -> Void,
            runtimeStatus: @escaping () -> CompanionRuntimeStatus? = { nil }
        ) {
            self.startTransport = startTransport
            self.stopTransport = stopTransport
            self.runtimeStatus = runtimeStatus
        }
    }

    public let statusStore: AgentStatusStore
    private let dependencies: Dependencies
    private var lifecycle: Lifecycle = .stopped {
        didSet { statusStore.publish(statusSnapshot()) }
    }
    private var observerCount = 0
    private var statusTimer: DispatchSourceTimer?

    public init(
        dependencies: Dependencies,
        statusStore: AgentStatusStore = AgentStatusStore()
    ) {
        self.dependencies = dependencies
        self.statusStore = statusStore
    }

    public static func live(profileStore: VoiceProfileStore = VoiceProfileStore()) -> CompanionAgent {
        let service = CompanionService(profileStore: profileStore)
        return CompanionAgent(
            dependencies: Dependencies(
                startTransport: { service.start() },
                stopTransport: { service.stop() },
                runtimeStatus: { service.runtimeStatus() }
            )
        )
    }

    public func start() {
        guard lifecycle == .stopped else { return }
        lifecycle = .starting
        dependencies.startTransport()
        lifecycle = .running
        publishRuntimeStatus()
        if dependencies.runtimeStatus() != nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                Task { @MainActor in self?.publishRuntimeStatus() }
            }
            timer.resume()
            statusTimer = timer
        }
    }

    public func stop() {
        guard lifecycle == .running || lifecycle == .starting else { return }
        lifecycle = .stopping
        dependencies.stopTransport()
        lifecycle = .stopped
        statusTimer?.cancel()
        statusTimer = nil
        publishRuntimeStatus()
    }

    public func attachGUIObserver() {
        observerCount += 1
    }

    public func detachGUIObserver() {
        observerCount = max(0, observerCount - 1)
        // Deliberately no stop(): the GUI is a client, not the runtime owner.
    }

    public func statusSnapshot() -> StatusSnapshot {
        StatusSnapshot(lifecycle: lifecycle)
    }

    private func publishRuntimeStatus() {
        guard var status = dependencies.runtimeStatus() else { return }
        status = CompanionRuntimeStatus(
            lifecycle: lifecycle,
            bleDescription: status.bleDescription,
            wifiDescription: status.wifiDescription,
            usbDescription: status.usbDescription,
            codexState: status.codexState,
            codexDetail: status.codexDetail,
            codexMicAvailable: status.codexMicAvailable,
            accessibilityAvailable: status.accessibilityAvailable
        )
        try? AgentStatusFile.write(status)
    }
}
#endif
