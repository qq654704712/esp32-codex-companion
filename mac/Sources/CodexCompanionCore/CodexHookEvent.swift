import Foundation

public enum DeviceState: String, Codable, CaseIterable, Sendable {
    case disconnected
    case idle
    case sessionStarting
    case working
    case writing
    case running
    case completed
    case error
    case approvalRequired
    case inputRequired
    case confirmationRequired
    case listening
    case voiceError
}

public struct CodexHookEvent: Equatable, Sendable {
    public let state: DeviceState
    public let sessionID: String?
    public let turnID: String?

    public init(state: DeviceState, sessionID: String? = nil, turnID: String? = nil) {
        self.state = state
        self.sessionID = sessionID
        self.turnID = turnID
    }
}

public enum CodexHookEventParser {
    public static func parse(_ data: Data) -> CodexHookEvent? {
        guard let payload = try? JSONDecoder().decode(WireEvent.self, from: data) else {
            return nil
        }
        let state: DeviceState
        switch payload.hookEventName {
        case "SessionStart": state = .sessionStarting
        case "UserPromptSubmit": state = .working
        case "PreToolUse":
            state = ["apply_patch", "write_file", "replace_file"].contains(payload.toolName)
                ? .writing : .running
        case "PostToolUse":
            state = payload.status == "failed" || payload.status == "error" ? .error : .working
        case "PermissionRequest": state = .approvalRequired
        case "Stop":
            state = payload.status == "failed" || payload.status == "error" ? .error : .completed
        default: return nil
        }
        return CodexHookEvent(
            state: state,
            sessionID: payload.sessionID,
            turnID: payload.turnID
        )
    }
}

private struct WireEvent: Decodable {
    let hookEventName: String
    let sessionID: String?
    let turnID: String?
    let status: String?
    let toolName: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case status
        case toolName = "tool_name"
    }
}
