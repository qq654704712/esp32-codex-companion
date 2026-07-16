import Foundation
import XCTest
@testable import CodexCompanionCore

final class HookInboxTests: XCTestCase {
    func testQueueAndDrain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = HookInbox(directoryURL: directory)
        let first = Data("{\"hook_event_name\":\"SessionStart\"}".utf8)
        let second = Data("{\"hook_event_name\":\"Stop\"}".utf8)

        try inbox.enqueue(first)
        try inbox.enqueue(second)
        let drained = try inbox.drain()

        XCTAssertEqual(Set(drained), Set([first, second]))
        XCTAssertTrue(try inbox.drain().isEmpty)
    }
}
