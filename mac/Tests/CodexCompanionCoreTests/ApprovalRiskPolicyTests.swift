import XCTest
@testable import CodexCompanionCore

final class ApprovalRiskPolicyTests: XCTestCase {
    func testClassifiesStableIdentifiersConservatively() {
        let policy = ApprovalRiskPolicy()
        XCTAssertFalse(policy.requiresLongPress(identifier: "approval.allow_once", title: "Allow once"))
        XCTAssertFalse(policy.requiresLongPress(identifier: "approval.deny", title: "Deny"))
        XCTAssertTrue(policy.requiresLongPress(identifier: "approval.allow_session", title: "Allow for session"))
        XCTAssertTrue(policy.requiresLongPress(identifier: "approval.unknown", title: "Allow"))
    }

    func testExcludesUnsafeActions() {
        let policy = ApprovalRiskPolicy()
        XCTAssertFalse(policy.isDeviceSelectable(identifier: "approval.other"))
        XCTAssertFalse(policy.isDeviceSelectable(identifier: "prompt.secret_input"))
        XCTAssertFalse(policy.isDeviceSelectable(identifier: "approval.option_4", title: "Other"))
        XCTAssertTrue(policy.isDeviceSelectable(identifier: "approval.allow_once"))
    }

    func testRecognizesInlinePlanAndPermissionButtons() {
        let policy = ApprovalRiskPolicy()
        XCTAssertTrue(policy.isInlinePromptButton(
            identifier: "request_user_input.option.0", title: "继续实施"
        ))
        XCTAssertTrue(policy.isInlinePromptButton(
            identifier: "approval.allow_once", title: "Allow once"
        ))
        XCTAssertFalse(policy.isInlinePromptButton(
            identifier: "sidebar.new_thread", title: "New task"
        ))
    }
}
