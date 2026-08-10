import Foundation

public enum CodexTaskEventKind: UInt8, Equatable, Sendable {
    case started = 0
    case completed = 1
}

public struct CodexTaskEvent: Equatable, Sendable {
    public let id: String
    public let kind: CodexTaskEventKind
    public let occurredAt: Date

    public init(id: String, kind: CodexTaskEventKind, occurredAt: Date) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
    }
}

/// Reads all recently active, user-visible Codex rollout journals. Task counts
/// come from explicit turn lifecycle boundaries instead of file activity: a
/// journal write is not itself another task, and a completed/aborted turn is
/// no longer active even if its file was modified a moment ago.
public struct CodexRolloutMonitor: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let state: DeviceState
        public let detail: String
        public let updatedAt: Date
        public let activeTasks: UInt8
        public let attentionTasks: UInt8
        public let recentCompletedTasks: UInt8
        public let events: [CodexTaskEvent]

        public init(
            state: DeviceState,
            detail: String,
            updatedAt: Date,
            activeTasks: UInt8,
            attentionTasks: UInt8,
            recentCompletedTasks: UInt8,
            events: [CodexTaskEvent] = []
        ) {
            self.state = state
            self.detail = detail
            self.updatedAt = updatedAt
            self.activeTasks = activeTasks
            self.attentionTasks = attentionTasks
            self.recentCompletedTasks = recentCompletedTasks
            self.events = events
        }
    }

    private struct SessionSnapshot {
        let state: DeviceState
        let detail: String
        let updatedAt: Date
        let isActive: Bool
        let completedAt: Date?
        let events: [CodexTaskEvent]
    }

    private struct Lifecycle {
        var currentTurnID: String?
        var isActive = false
        var completedAt: Date?
        var events: [CodexTaskEvent] = []
        var classification: (state: DeviceState, detail: String)?
    }

    private struct CachedSession {
        var offset: UInt64 = 0
        var pending = Data()
        var lineNumber = 0
        var lifecycle = Lifecycle()
    }

    private let root: URL
    private let idleTimeout: TimeInterval
    private let completedVisibility: TimeInterval
    private var lastSignature: String?
    private var hasSeededEvents = false
    private var seenEventIDs: Set<String> = []
    private var seenEventOrder: [String] = []
    private var sessionCache: [String: CachedSession] = [:]

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        idleTimeout: TimeInterval = 600,
        completedVisibility: TimeInterval = 15
    ) {
        self.root = root
        self.idleTimeout = idleTimeout
        self.completedVisibility = completedVisibility
    }

    public mutating func poll(now: Date = Date()) -> Snapshot? {
        var sessions: [SessionSnapshot] = []
        var allEvents: [CodexTaskEvent] = []
        var retainedCacheKeys: Set<String> = []
        for (file, modified) in recentRollouts(limit: 100) {
            guard now.timeIntervalSince(modified) <= max(idleTimeout, completedVisibility) else {
                continue
            }
            let key = file.path
            retainedCacheKeys.insert(key)
            var cache = sessionCache[key] ?? CachedSession()
            guard update(&cache, from: file, modified: modified) else { continue }
            let lifecycle = cache.lifecycle
            allEvents.append(contentsOf: lifecycle.events)
            cache.lifecycle.events.removeAll(keepingCapacity: true)
            sessionCache[key] = cache
            // An unclosed turn from a crashed process must eventually age out,
            // but normal long-running tool calls get a substantially wider
            // window than the former 60-second "recent file" heuristic.
            let active = lifecycle.isActive && now.timeIntervalSince(modified) <= idleTimeout
            guard active || lifecycle.completedAt != nil else { continue }
            let classified = active
                ? lifecycle.classification ?? (.sessionStarting, "正在准备会话")
                : (.completed, "任务完成")
            sessions.append(SessionSnapshot(
                state: classified.state,
                detail: classified.detail,
                updatedAt: modified,
                isActive: active,
                completedAt: lifecycle.completedAt,
                events: []
            ))
        }
        sessionCache = sessionCache.filter { retainedCacheKeys.contains($0.key) }

        allEvents.sort { $0.occurredAt < $1.occurredAt }
        let events: [CodexTaskEvent]
        if hasSeededEvents {
            events = allEvents.filter { rememberEvent($0.id) }
        } else {
            allEvents.forEach { _ = rememberEvent($0.id) }
            hasSeededEvents = true
            events = []
        }

        let active = sessions.filter(\.isActive)
        let attention = active.filter { Self.needsAttention($0.state) }
        let completed = sessions.filter {
            guard let completedAt = $0.completedAt else { return false }
            return now.timeIntervalSince(completedAt) <= completedVisibility
        }
        let selected = selectVisible(active: active, attention: attention, completed: completed)
        let activeCount = UInt8(clamping: active.count)
        let attentionCount = UInt8(clamping: attention.count)
        let completedCount = UInt8(clamping: completed.count)
        let detail = activeCount > 1 || attentionCount > 0
            ? "\(activeCount) 个对话 · \(attentionCount) 个待处理"
            : selected.detail
        let snapshot = Snapshot(
            state: selected.state,
            detail: detail,
            updatedAt: selected.updatedAt,
            activeTasks: activeCount,
            attentionTasks: attentionCount,
            recentCompletedTasks: completedCount,
            events: events
        )
        return publishIfChanged(snapshot)
    }

    private mutating func rememberEvent(_ id: String) -> Bool {
        guard seenEventIDs.insert(id).inserted else { return false }
        seenEventOrder.append(id)
        if seenEventOrder.count > 512 {
            let excess = seenEventOrder.count - 512
            let removed = Array(seenEventOrder.prefix(excess))
            seenEventOrder.removeFirst(excess)
            removed.forEach { seenEventIDs.remove($0) }
        }
        return true
    }

    private mutating func publishIfChanged(_ snapshot: Snapshot) -> Snapshot? {
        let signature = [
            String(snapshot.state.rawValue), snapshot.detail,
            String(snapshot.activeTasks), String(snapshot.attentionTasks),
            String(snapshot.recentCompletedTasks),
        ].joined(separator: "|")
        guard signature != lastSignature || !snapshot.events.isEmpty else { return nil }
        lastSignature = signature
        return snapshot
    }

    private func selectVisible(
        active: [SessionSnapshot], attention: [SessionSnapshot], completed: [SessionSnapshot]
    ) -> SessionSnapshot {
        if let item = attention.max(by: { priority($0.state) < priority($1.state) }) { return item }
        if let item = active.max(by: {
            let lhs = priority($0.state), rhs = priority($1.state)
            return lhs == rhs ? $0.updatedAt < $1.updatedAt : lhs < rhs
        }) { return item }
        if let item = completed.max(by: { $0.updatedAt < $1.updatedAt }) { return item }
        return SessionSnapshot(
            state: .idle, detail: "Codex 空闲", updatedAt: Date(),
            isActive: false, completedAt: nil, events: []
        )
    }

    private func priority(_ state: DeviceState) -> Int {
        switch state {
        case .error, .voiceError: 90
        case .approvalRequired, .inputRequired, .confirmationRequired: 80
        case .running: 60
        case .working: 40
        case .sessionStarting: 30
        case .completed: 10
        default: 0
        }
    }

    private static func needsAttention(_ state: DeviceState) -> Bool {
        switch state {
        case .error, .voiceError, .approvalRequired, .inputRequired, .confirmationRequired: true
        default: false
        }
    }

    private func update(
        _ cache: inout CachedSession, from file: URL, modified: Date
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < cache.offset { cache = CachedSession() }
        guard size > cache.offset else { return true }
        try? handle.seek(toOffset: cache.offset)
        guard let appended = try? handle.readToEnd() else { return false }
        cache.offset = size
        cache.pending.append(appended)
        guard let newline = cache.pending.lastIndex(of: 0x0A) else { return true }
        let complete = Data(cache.pending[...newline])
        let remainderStart = cache.pending.index(after: newline)
        cache.pending = remainderStart < cache.pending.endIndex
            ? Data(cache.pending[remainderStart...]) : Data()
        guard let text = String(data: complete, encoding: .utf8) else { return false }
        apply(text, sourceID: file.path, fallbackDate: modified, cache: &cache)
        return true
    }

    private func apply(
        _ text: String, sourceID: String, fallbackDate: Date,
        cache: inout CachedSession
    ) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            cache.lineNumber += 1
            guard let data = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = object["type"] as? String ?? ""
            let payload = object["payload"] as? [String: Any] ?? object
            let payloadType = payload["type"] as? String ?? ""
            let date = parseDate(object["timestamp"]) ?? parseDate(payload["timestamp"]) ?? fallbackDate

            if type == "turn_context" {
                let turnID = payload["turn_id"] as? String ?? "line-\(cache.lineNumber)"
                cache.lifecycle.currentTurnID = turnID
                cache.lifecycle.isActive = true
                cache.lifecycle.completedAt = nil
                cache.lifecycle.classification = (.sessionStarting, "正在准备会话")
                cache.lifecycle.events.append(CodexTaskEvent(
                    id: "\(sourceID)|\(turnID)|started", kind: .started, occurredAt: date
                ))
                continue
            }
            if payloadType == "task_complete" || payloadType == "turn_aborted" {
                let turnID = payload["turn_id"] as? String ??
                    cache.lifecycle.currentTurnID ?? "line-\(cache.lineNumber)"
                if cache.lifecycle.currentTurnID == nil || cache.lifecycle.currentTurnID == turnID {
                    cache.lifecycle.isActive = false
                    cache.lifecycle.completedAt = payloadType == "task_complete" ? date : nil
                }
                if payloadType == "task_complete" {
                    cache.lifecycle.events.append(CodexTaskEvent(
                        id: "\(sourceID)|\(turnID)|completed", kind: .completed, occurredAt: date
                    ))
                }
                continue
            }
            if cache.lifecycle.isActive, let classified = classify(object) {
                cache.lifecycle.classification = classified
            }
        }
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func recentRollouts(limit: Int) -> [(URL, Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  isUserVisibleRollout(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            result.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return result.sorted { $0.1 > $1.1 }.prefix(limit).map { $0 }
    }

    private func isUserVisibleRollout(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // session_meta can be hundreds of kilobytes because it embeds the
        // complete instruction set. Read the first JSON line in bounded chunks
        // instead of assuming its source marker fits inside the first 16 KiB.
        var data = Data()
        while data.count < 1_048_576, data.firstIndex(of: 0x0A) == nil {
            guard let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("\"source\":{\"subagent\"") ||
            text.contains("\"thread_source\":\"subagent\"") {
            return false
        }
        guard let newline = data.firstIndex(of: 0x0A),
              let object = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return true }
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return false }
        return true
    }

    private func classify(_ entry: [String: Any]) -> (state: DeviceState, detail: String)? {
        let type = entry["type"] as? String ?? ""
        let payload = entry["payload"] as? [String: Any] ?? entry
        let payloadType = payload["type"] as? String ?? ""
        let status = payload["status"] as? String ?? ""
        let name = payload["name"] as? String ?? payload["tool"] as? String
        let normalizedName = name?.lowercased() ?? ""

        if type == "compacted" { return (.working, "正在压缩上下文") }
        if ["error", "failed"].contains(payloadType) || ["error", "failed"].contains(status) {
            return (.error, "Codex 报告错误")
        }
        if ["ask_user", "user_intervention", "permission_request"].contains(payloadType) ||
            ["requires_action", "authorization_required"].contains(status) {
            return (.approvalRequired, "等待你的确认")
        }
        if normalizedName.contains("request_user_input") ||
            normalizedName.contains("ask_user") {
            return (.inputRequired, "等待你选择")
        }
        if normalizedName.contains("permission") || normalizedName.contains("approval") {
            return (.approvalRequired, "等待你的授权")
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
        // Agent messages no longer create a separate "writing" state. They
        // are ordinary output within the active turn and must not mask queued
        // start/completion animations from other conversations.
        return nil
    }
}
