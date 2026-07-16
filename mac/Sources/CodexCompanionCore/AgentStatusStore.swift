#if os(macOS)
import Combine
import Foundation

@MainActor
public final class AgentStatusStore: ObservableObject {
    @Published public private(set) var snapshot: CompanionAgent.StatusSnapshot

    public init(initial: CompanionAgent.StatusSnapshot = .init(lifecycle: .stopped)) {
        snapshot = initial
    }

    func publish(_ snapshot: CompanionAgent.StatusSnapshot) {
        self.snapshot = snapshot
    }
}
#endif
