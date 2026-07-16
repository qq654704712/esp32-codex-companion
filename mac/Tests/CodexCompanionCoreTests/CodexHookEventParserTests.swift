import Foundation
import XCTest
@testable import CodexCompanionCore

final class CodexHookEventParserTests: XCTestCase {
    func testMapsSupportedEvents() throws {
        let cases: [(String, DeviceState)] = [
            ("SessionStart", .sessionStarting),
            ("UserPromptSubmit", .working),
            ("PermissionRequest", .approvalRequired),
            ("Stop", .completed),
        ]

        for (name, expected) in cases {
            let data = Data("""
                {"hook_event_name":"\(name)","session_id":"s-1","turn_id":"t-2"}
                """.utf8)
            let event = try XCTUnwrap(CodexHookEventParser.parse(data))
            XCTAssertEqual(event.state, expected)
            XCTAssertEqual(event.sessionID, "s-1")
            XCTAssertEqual(event.turnID, "t-2")
        }
    }

    func testRejectsUnsupportedInput() {
        XCTAssertNil(CodexHookEventParser.parse(Data("{\"hook_event_name\":\"UnknownEvent\"}".utf8)))
        XCTAssertNil(CodexHookEventParser.parse(Data("not json".utf8)))
    }

    func testMapsExplicitFailure() throws {
        let data = Data("""
            {"hook_event_name":"Stop","status":"failed","session_id":"s-1"}
            """.utf8)
        XCTAssertEqual(try XCTUnwrap(CodexHookEventParser.parse(data)).state, .error)
    }

    func testMapsToolLifecycleToWorkingAndToolFailureToError() throws {
        let beforeTool = Data("""
            {"hook_event_name":"PreToolUse","tool_name":"apply_patch"}
            """.utf8)
        let afterTool = Data("""
            {"hook_event_name":"PostToolUse","tool_name":"exec_command"}
            """.utf8)
        let failedTool = Data("""
            {"hook_event_name":"PostToolUse","status":"failed","tool_name":"exec_command"}
            """.utf8)

        XCTAssertEqual(try XCTUnwrap(CodexHookEventParser.parse(beforeTool)).state, .writing)
        XCTAssertEqual(try XCTUnwrap(CodexHookEventParser.parse(afterTool)).state, .working)
        XCTAssertEqual(try XCTUnwrap(CodexHookEventParser.parse(failedTool)).state, .error)
    }
}
