import Foundation

/// Reads Codex's local rollout journal directly. This mirrors the robust part
/// of the traffic-light approach: it works even when no hook was installed,
/// recovers the active state when Companion starts mid-turn, and returns to an
/// honest idle state when journal activity stops.
public struct CodexRolloutMonitor: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let state: DeviceState
        public let detail: String
        public let updatedAt: Date
    }

    private let root: URL
    private let idleTimeout: TimeInterval
    private var lastSignature: String?
    private var lastSnapshot: Snapshot?

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        idleTimeout: TimeInterval = 60
    ) {
        self.root = root
        self.idleTimeout = idleTimeout
    }

    /// Returns a value only when the visible state changed. Callers can poll
    /// this cheaply (the current rollout is tailed, not the full history).
    public mutating func poll(now: Date = Date()) -> Snapshot? {
        guard let file = newestRollout() else {
            return publishIfChanged(Snapshot(state: .idle, detail: "等待 Codex 会话", updatedAt: now))
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        guard now.timeIntervalSince(modified) <= idleTimeout else {
            return publishIfChanged(Snapshot(state: .idle, detail: "Codex 空闲", updatedAt: now))
        }
        guard let data = tail(file: file, maximumBytes: 512 * 1024),
              let text = String(data: data, encoding: .utf8),
              let classified = classifyLatest(in: text) else {
            return publishIfChanged(Snapshot(state: .working, detail: "正在准备上下文", updatedAt: modified))
        }
        return publishIfChanged(Snapshot(state: classified.state,
                                         detail: classified.detail,
                                         updatedAt: modified))
    }

    private mutating func publishIfChanged(_ snapshot: Snapshot) -> Snapshot? {
        let signature = "\(snapshot.state.rawValue)|\(snapshot.detail)"
        guard signature != lastSignature else {
            lastSnapshot = snapshot
            return nil
        }
        lastSignature = signature
        lastSnapshot = snapshot
        return snapshot
    }

    private func newestRollout() -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var newest: (url: URL, modified: Date)?
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.modified { newest = (url, modified) }
        }
        return newest?.url
    }

    private func tail(file: URL, maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: offset)
        var data = try? handle.readToEnd()
        // A bounded tail can begin halfway through a JSON line; discard it.
        if offset > 0, let newline = data?.firstIndex(of: 0x0A) {
            data = Data(data![(data!.index(after: newline))...])
        }
        return data
    }

    private func classifyLatest(in text: String) -> (state: DeviceState, detail: String)? {
        var result: (state: DeviceState, detail: String)?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let data = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let classified = classify(object) { result = classified }
        }
        return result
    }

    private func classify(_ entry: [String: Any]) -> (state: DeviceState, detail: String)? {
        let type = entry["type"] as? String ?? ""
        let payload = entry["payload"] as? [String: Any] ?? entry
        let payloadType = payload["type"] as? String ?? ""
        let phase = payload["phase"] as? String ?? ""
        let status = payload["status"] as? String ?? ""
        let name = payload["name"] as? String ?? payload["tool"] as? String

        if type == "compacted" { return (.working, "正在压缩上下文") }
        if ["error", "failed"].contains(payloadType) || ["error", "failed"].contains(status) {
            return (.error, "Codex 报告错误")
        }
        if ["ask_user", "user_intervention", "permission_request"].contains(payloadType) ||
            ["requires_action", "authorization_required"].contains(status) {
            return (.approvalRequired, "等待你的确认")
        }
        if type == "turn_context" || type == "session_meta" {
            return (.sessionStarting, "正在准备会话")
        }
        if payloadType == "reasoning" || payloadType == "agent_reasoning" {
            return (.working, "正在思考")
        }
        if ["custom_tool_call", "function_call", "web_search_call", "tool_call"].contains(payloadType) {
            return (.running, "正在执行：\(name ?? "工具")")
        }
        if ["custom_tool_call_output", "function_call_output", "patch_apply_end"].contains(payloadType) {
            return (.working, "正在处理执行结果")
        }
        if payloadType == "task_complete" || phase == "final_answer" {
            return (.completed, "任务完成")
        }
        if payloadType == "agent_message" || payloadType == "message" || type == "response_item" {
            return (.writing, "正在生成回复")
        }
        return nil
    }
}
