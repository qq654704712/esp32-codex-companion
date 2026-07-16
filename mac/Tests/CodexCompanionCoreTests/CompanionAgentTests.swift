import XCTest
@testable import CodexCompanionCore

@MainActor
final class CompanionAgentTests: XCTestCase {
    func testClosingObserverDoesNotStopRunningAgent() {
        var starts = 0
        let agent = CompanionAgent(dependencies: .init(
            startTransport: { starts += 1 },
            stopTransport: {}
        ))

        agent.start()
        agent.detachGUIObserver()

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(agent.statusSnapshot().lifecycle, .running)
    }

    func testStartIsIdempotentAndStopReleasesTransportOnce() {
        var starts = 0
        var stops = 0
        let agent = CompanionAgent(dependencies: .init(
            startTransport: { starts += 1 },
            stopTransport: { stops += 1 }
        ))

        agent.start()
        agent.start()
        agent.stop()
        agent.stop()

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(agent.statusSnapshot().lifecycle, .stopped)
    }
}
