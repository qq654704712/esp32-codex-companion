import Foundation

public struct CompanionRuntimeStatus: Codable, Equatable, Sendable {
    public let lifecycle: CompanionAgent.Lifecycle
    public let bleDescription: String
    public let wifiDescription: String
    public let usbDescription: String
    public let codexState: DeviceState
    public let codexDetail: String
    public let codexMicAvailable: Bool
    public let accessibilityAvailable: Bool
    public let updatedAt: Date

    public init(
        lifecycle: CompanionAgent.Lifecycle,
        bleDescription: String,
        wifiDescription: String = "未启动",
        usbDescription: String = "未启动",
        codexState: DeviceState = .idle,
        codexDetail: String = "等待 Codex 会话",
        codexMicAvailable: Bool,
        accessibilityAvailable: Bool,
        updatedAt: Date = Date()
    ) {
        self.lifecycle = lifecycle
        self.bleDescription = bleDescription
        self.wifiDescription = wifiDescription
        self.usbDescription = usbDescription
        self.codexState = codexState
        self.codexDetail = codexDetail
        self.codexMicAvailable = codexMicAvailable
        self.accessibilityAvailable = accessibilityAvailable
        self.updatedAt = updatedAt
    }

    public static let stopped = CompanionRuntimeStatus(
        lifecycle: .stopped,
        bleDescription: "未连接",
        codexMicAvailable: false,
        accessibilityAvailable: false
    )

    private enum CodingKeys: String, CodingKey {
        case lifecycle, bleDescription, wifiDescription, usbDescription,
             codexState, codexDetail, codexMicAvailable, accessibilityAvailable,
             updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lifecycle = try values.decode(CompanionAgent.Lifecycle.self, forKey: .lifecycle)
        bleDescription = try values.decode(String.self, forKey: .bleDescription)
        wifiDescription = try values.decodeIfPresent(String.self, forKey: .wifiDescription) ?? "未启动"
        usbDescription = try values.decodeIfPresent(String.self, forKey: .usbDescription) ?? "未启动"
        codexState = try values.decodeIfPresent(DeviceState.self, forKey: .codexState) ?? .idle
        codexDetail = try values.decodeIfPresent(String.self, forKey: .codexDetail) ?? "等待 Codex 会话"
        codexMicAvailable = try values.decode(Bool.self, forKey: .codexMicAvailable)
        accessibilityAvailable = try values.decode(Bool.self, forKey: .accessibilityAvailable)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

public enum AgentStatusFile {
    public static let defaultURL: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return root.appendingPathComponent("CodexCompanion", isDirectory: true)
            .appendingPathComponent("agent-status.json")
    }()

    public static func write(_ status: CompanionRuntimeStatus, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(status)
        try data.write(to: url, options: [.atomic])
    }

    public static func read(from url: URL = defaultURL) throws -> CompanionRuntimeStatus {
        try JSONDecoder().decode(CompanionRuntimeStatus.self, from: Data(contentsOf: url))
    }
}
