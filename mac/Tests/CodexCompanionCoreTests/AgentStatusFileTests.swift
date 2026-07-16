import Foundation
import XCTest
@testable import CodexCompanionCore

final class AgentStatusFileTests: XCTestCase {
    func testWritesAndReadsBackgroundAgentStatus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("status.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = CompanionRuntimeStatus(
            lifecycle: .running,
            bleDescription: "已连接",
            codexMicAvailable: true,
            accessibilityAvailable: true,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        try AgentStatusFile.write(status, to: url)

        XCTAssertEqual(try AgentStatusFile.read(from: url), status)
    }

    func testReadsStatusWrittenBeforeWiFiFieldExisted() throws {
        let json = """
        {"lifecycle":"running","bleDescription":"已连接","codexMicAvailable":true,"accessibilityAvailable":true,"updatedAt":0}
        """.data(using: .utf8)!
        let status = try JSONDecoder().decode(CompanionRuntimeStatus.self, from: json)
        XCTAssertEqual(status.wifiDescription, "未启动")
    }
}
