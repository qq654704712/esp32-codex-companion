import Foundation
import XCTest
@testable import CodexCompanionCore

final class CodexRolloutMonitorTests: XCTestCase {
    func testCountsOnlyExplicitlyOpenUserVisibleTurns() throws {
        let (root, now) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(root.appendingPathComponent("rollout-one.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "one"], at: now.addingTimeInterval(-4)),
            entry(type: "event_msg", payload: ["type": "custom_tool_call"], at: now.addingTimeInterval(-3)),
        ], modifiedAt: now.addingTimeInterval(-2))
        try writeRollout(root.appendingPathComponent("rollout-two.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "two"], at: now.addingTimeInterval(-4)),
            entry(type: "event_msg", payload: ["type": "permission_request"], at: now.addingTimeInterval(-3)),
        ], modifiedAt: now.addingTimeInterval(-2))
        try writeRollout(root.appendingPathComponent("rollout-finished.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "done"], at: now.addingTimeInterval(-5)),
            entry(type: "event_msg", payload: ["type": "task_complete", "turn_id": "done"], at: now.addingTimeInterval(-1)),
        ], modifiedAt: now.addingTimeInterval(-1))
        try writeRollout(root.appendingPathComponent("rollout-aborted.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "stopped"], at: now.addingTimeInterval(-5)),
            entry(type: "event_msg", payload: ["type": "turn_aborted", "turn_id": "stopped"], at: now.addingTimeInterval(-1)),
        ], modifiedAt: now.addingTimeInterval(-1))
        var monitor = CodexRolloutMonitor(root: root, idleTimeout: 60)

        let snapshot = try XCTUnwrap(monitor.poll(now: now))

        XCTAssertEqual(snapshot.state, .approvalRequired)
        XCTAssertEqual(snapshot.activeTasks, 2)
        XCTAssertEqual(snapshot.attentionTasks, 1)
        XCTAssertEqual(snapshot.recentCompletedTasks, 1)
        XCTAssertEqual(snapshot.detail, "2 个对话 · 1 个待处理")
        XCTAssertTrue(snapshot.events.isEmpty, "launch must not replay historical sounds")
    }

    func testCompletionEventPublishesWhileAnotherTurnKeepsRunning() throws {
        let (root, now) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runningURL = root.appendingPathComponent("rollout-running.jsonl")
        let secondURL = root.appendingPathComponent("rollout-second.jsonl")
        try writeRollout(runningURL, entries: [
            entry(type: "turn_context", payload: ["turn_id": "running"], at: now.addingTimeInterval(-4)),
            entry(type: "event_msg", payload: ["type": "function_call"], at: now.addingTimeInterval(-3)),
        ], modifiedAt: now.addingTimeInterval(-3))
        try writeRollout(secondURL, entries: [
            entry(type: "turn_context", payload: ["turn_id": "second"], at: now.addingTimeInterval(-2)),
        ], modifiedAt: now.addingTimeInterval(-2))
        var monitor = CodexRolloutMonitor(root: root, idleTimeout: 60)
        _ = try XCTUnwrap(monitor.poll(now: now))

        try append(
            entry(type: "event_msg", payload: ["type": "task_complete", "turn_id": "second"], at: now),
            to: secondURL,
            modifiedAt: now
        )
        let snapshot = try XCTUnwrap(monitor.poll(now: now.addingTimeInterval(0.1)))

        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.activeTasks, 1)
        XCTAssertEqual(snapshot.events.map(\.kind), [.completed])
        XCTAssertNil(monitor.poll(now: now.addingTimeInterval(0.2)), "event must be emitted once")
    }

    func testNewStartEventPublishesEvenWhenAggregateStateDoesNotChange() throws {
        let (root, now) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("rollout-first.jsonl")
        try writeRollout(first, entries: [
            entry(type: "turn_context", payload: ["turn_id": "first"], at: now.addingTimeInterval(-2)),
            entry(type: "event_msg", payload: ["type": "reasoning"], at: now.addingTimeInterval(-1)),
        ], modifiedAt: now.addingTimeInterval(-1))
        var monitor = CodexRolloutMonitor(root: root, idleTimeout: 60)
        _ = try XCTUnwrap(monitor.poll(now: now))

        try writeRollout(root.appendingPathComponent("rollout-new.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "new"], at: now.addingTimeInterval(1)),
            entry(type: "event_msg", payload: ["type": "reasoning"], at: now.addingTimeInterval(1)),
        ], modifiedAt: now.addingTimeInterval(1))
        let snapshot = try XCTUnwrap(monitor.poll(now: now.addingTimeInterval(1)))

        XCTAssertEqual(snapshot.activeTasks, 2)
        XCTAssertEqual(snapshot.events.map(\.kind), [.started])
    }

    func testAgentMessageDoesNotCreateWritingState() throws {
        let (root, now) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(root.appendingPathComponent("rollout-message.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "one"], at: now.addingTimeInterval(-2)),
            entry(type: "event_msg", payload: ["type": "reasoning"], at: now.addingTimeInterval(-1)),
            entry(type: "event_msg", payload: ["type": "agent_message"], at: now),
        ], modifiedAt: now)
        var monitor = CodexRolloutMonitor(root: root, idleTimeout: 60)

        XCTAssertEqual(try XCTUnwrap(monitor.poll(now: now)).state, .working)
    }

    func testRequestUserInputToolBecomesDeviceChoiceState() throws {
        let (root, now) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(root.appendingPathComponent("rollout-question.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "question"], at: now.addingTimeInterval(-1)),
            entry(type: "response_item", payload: [
                "type": "custom_tool_call", "name": "request_user_input",
            ], at: now),
        ], modifiedAt: now)
        var monitor = CodexRolloutMonitor(root: root, idleTimeout: 60)
        XCTAssertEqual(try XCTUnwrap(monitor.poll(now: now)).state, .inputRequired)
    }

    func testLargeJournalKeepsTurnContextOutsideFormerTailWindow() throws {
        let (root, now) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(root.appendingPathComponent("rollout-large.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "large"], at: now.addingTimeInterval(-2)),
            entry(type: "event_msg", payload: [
                "type": "user_message",
                "message": String(repeating: "x", count: 700_000),
            ], at: now.addingTimeInterval(-1)),
            entry(type: "event_msg", payload: ["type": "reasoning"], at: now),
        ], modifiedAt: now)
        var monitor = CodexRolloutMonitor(root: root, idleTimeout: 60)

        let snapshot = try XCTUnwrap(monitor.poll(now: now))
        XCTAssertEqual(snapshot.activeTasks, 1)
        XCTAssertEqual(snapshot.state, .working)
    }

    func testLargeInternalSubagentMetadataIsNotCountedAsAConversation() throws {
        let (root, now) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRollout(root.appendingPathComponent("rollout-visible.jsonl"), entries: [
            entry(type: "turn_context", payload: ["turn_id": "visible"], at: now),
        ], modifiedAt: now)
        try writeRollout(root.appendingPathComponent("rollout-internal.jsonl"), entries: [
            [
                "type": "session_meta",
                "payload": [
                    "source": ["subagent": ["thread_spawn": ["depth": 1]]],
                    "base_instructions": String(repeating: "instruction", count: 4_000),
                ],
            ],
            entry(type: "turn_context", payload: ["turn_id": "internal"], at: now),
        ], modifiedAt: now)
        var monitor = CodexRolloutMonitor(root: root, idleTimeout: 60)

        XCTAssertEqual(try XCTUnwrap(monitor.poll(now: now)).activeTasks, 1)
    }

    private func makeRoot() throws -> (URL, Date) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, Date(timeIntervalSince1970: 2_000))
    }

    private func entry(type: String, payload: [String: Any], at date: Date) -> [String: Any] {
        ["type": type, "timestamp": ISO8601DateFormatter().string(from: date), "payload": payload]
    }

    private func writeRollout(_ url: URL, entries: [[String: Any]], modifiedAt: Date) throws {
        var data = Data()
        for object in entries {
            data.append(try JSONSerialization.data(withJSONObject: object))
            data.append(0x0A)
        }
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    private func append(_ object: [String: Any], to url: URL, modifiedAt: Date) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }
}
