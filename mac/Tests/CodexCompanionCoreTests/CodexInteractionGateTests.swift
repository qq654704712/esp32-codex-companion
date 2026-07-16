import XCTest
@testable import CodexCompanionCore

final class CodexInteractionGateTests: XCTestCase {
    func testElectronContentEditableAncestorIsRecognized() {
        XCTAssertTrue(CodexAccessibilityInspector.isEditable(
            valueIsSettable: false,
            hasEditableAncestor: true
        ))
        XCTAssertFalse(CodexAccessibilityInspector.isEditable(
            valueIsSettable: false,
            hasEditableAncestor: false
        ))
    }

    func testRequiresCodexComposer() {
        let gate = CodexInteractionGate()
        XCTAssertTrue(gate.allowsVoiceInput(.init(bundleIdentifier: "com.openai.codex", role: "AXTextArea", isEditable: true, isSecure: false)))
        XCTAssertFalse(gate.allowsVoiceInput(.init(bundleIdentifier: "com.example.notes", role: "AXTextArea", isEditable: true, isSecure: false)))
        XCTAssertFalse(gate.allowsVoiceInput(.init(bundleIdentifier: "com.openai.codex", role: "AXButton", isEditable: false, isSecure: false)))
        XCTAssertFalse(gate.allowsVoiceInput(.init(bundleIdentifier: "com.openai.codex", role: "AXTextField", isEditable: true, isSecure: true)))
    }
}
