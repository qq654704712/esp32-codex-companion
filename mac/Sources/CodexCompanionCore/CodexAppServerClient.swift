#if os(macOS)
import Darwin
import Foundation

public enum CodexRateLimitParserError: Error, Equatable {
    case invalidResponse
    case serverError(String)
}

public enum CodexRateLimitParser {
    public static func parseResponse(_ data: Data, updatedAt: Int64) throws -> QuotaSnapshot {
        let response = try JSONDecoder().decode(RateLimitRPCResponse.self, from: data)
        if let error = response.error {
            throw CodexRateLimitParserError.serverError(error.message)
        }
        guard let result = response.result else {
            throw CodexRateLimitParserError.invalidResponse
        }
        let selected = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        let windows = [selected.primary, selected.secondary].compactMap { window -> RateLimitWindow? in
            guard let window, let duration = window.windowDurationMins else { return nil }
            return RateLimitWindow(
                windowDurationMins: duration,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt
            )
        }
        return QuotaMapper.map(windows: windows, updatedAt: updatedAt)
    }
}

private struct RateLimitRPCResponse: Decodable {
    struct RPCError: Decodable { let message: String }
    let result: RateLimitResult?
    let error: RPCError?
}

private struct RateLimitResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

private struct RateLimitSnapshot: Decodable {
    let primary: RateLimitWireWindow?
    let secondary: RateLimitWireWindow?
}

private struct RateLimitWireWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

public enum CodexAppServerError: Error, Equatable {
    case launchFailed(String)
    case timeout
    case pipeClosed
    case invalidJSON
    case rpcError(String)
}

public final class CodexAppServerClient: @unchecked Sendable {
    private let executable: String

    public init(executable: String = "codex") {
        self.executable = executable
    }

    public func readQuota(timeout: TimeInterval = 10) throws -> QuotaSnapshot {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
        defer {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        try send([
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "codex_companion",
                    "title": "Codex Companion",
                    "version": "0.1.0",
                ],
            ],
        ], to: input.fileHandleForWriting)
        let reader = JSONLineReader(fileDescriptor: output.fileHandleForReading.fileDescriptor)
        _ = try readResponse(id: 1, reader: reader, deadline: deadline)
        try send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
        try send(
            ["method": "account/rateLimits/read", "id": 2, "params": NSNull()],
            to: input.fileHandleForWriting
        )
        let response = try readResponse(id: 2, reader: reader, deadline: deadline)
        return try CodexRateLimitParser.parseResponse(
            response,
            updatedAt: Int64(Date().timeIntervalSince1970)
        )
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.pipeClosed
        }
    }

    private func readResponse(
        id: Int,
        reader: JSONLineReader,
        deadline: Date
    ) throws -> Data {
        while Date() < deadline {
            let line = try reader.readLine(deadline: deadline)
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexAppServerError.invalidJSON
            }
            guard (object["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw CodexAppServerError.rpcError(error["message"] as? String ?? "unknown error")
            }
            return line
        }
        throw CodexAppServerError.timeout
    }
}

private final class JSONLineReader {
    private let fileDescriptor: Int32
    private var buffer = Data()

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func readLine(deadline: Date) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            if remaining == 0 { throw CodexAppServerError.timeout }
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result == 0 { throw CodexAppServerError.timeout }
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexAppServerError.pipeClosed
            }
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(fileDescriptor, &chunk, chunk.count)
            guard count > 0 else { throw CodexAppServerError.pipeClosed }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}
#endif
