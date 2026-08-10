import Foundation
import XCTest
@testable import CodexCompanionCore

final class CompanionControlReducerTests: XCTestCase {
    func testOlderRevisionCannotReplaceCurrentApproval() {
        var reducer = CompanionControlReducer(now: { Date(timeIntervalSince1970: 100) })
        let first = reducer.reduce(hook: .init(state: .approvalRequired, sessionID: "s", turnID: "1"))
        let second = reducer.reduce(hook: .init(state: .approvalRequired, sessionID: "s", turnID: "2"))

        XCTAssertLessThan(first.revision, second.revision)
        XCTAssertNil(reducer.applyRemoteAcknowledgement(revision: first.revision))
        XCTAssertEqual(reducer.applyRemoteAcknowledgement(revision: second.revision)?.revision, second.revision)
    }

    func testApprovalHasBoundedActionAndExpiry() {
        var reducer = CompanionControlReducer(now: { Date(timeIntervalSince1970: 100) })
        let state = reducer.reduce(hook: .init(state: .approvalRequired, sessionID: "s", turnID: "2"))

        XCTAssertNotNil(state.actionID)
        XCTAssertEqual(state.expiresAt, Date(timeIntervalSince1970: 130))
    }

    func testPlanChoiceHasSameBoundedRemoteAuthority() {
        var reducer = CompanionControlReducer(now: { Date(timeIntervalSince1970: 100) })
        let state = reducer.reduce(hook: .init(state: .inputRequired))
        XCTAssertNotNil(state.actionID)
        XCTAssertEqual(state.expiresAt, Date(timeIntervalSince1970: 130))
    }

    func testApplyPatchUsesRunningStateWithoutWritingHeuristic() throws {
        let event = try XCTUnwrap(CodexHookEventParser.parse(Data(
            "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"apply_patch\"}".utf8
        )))
        XCTAssertEqual(event.state, .running)
    }
}
