#if os(macOS)
import Darwin
import Foundation

public enum CodexMicSocketError: Error, Equatable {
    case pathTooLong
    case socketCreationFailed(Int32)
    case connectionFailed(Int32)
    case writeFailed(Int32)
}

public final class CodexMicSocketClient: FloatAudioSink {
    public let socketPath: String
    private var descriptor: Int32 = -1
    private var endpointDeadline: Date?
    private var clearPending = false
    private let lock = NSLock()

    // CoreAudio hosts HAL plug-ins as _coreaudiod, not as the foreground user.
    // The endpoint must therefore be independent of either process's UID.
    public init(socketPath: String = "/tmp/codex-mic.sock") {
        self.socketPath = socketPath
    }

    deinit { disconnect() }

    public func connectIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        try connectIfNeededLocked()
    }

    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        endpointDeadline = nil
        clearPending = false
    }

    public func write(samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try connectSessionIfNeededLocked()
        } catch {
            // A CoreAudio HAL input driver only creates its socket after the
            // input method starts recording. The first BLE frames can arrive
            // a few hundred milliseconds earlier than that transition.
            if shouldWaitForEndpoint(error) { return }
            throw error
        }
        var header = Data("CMIC".utf8)
        var count = UInt32(samples.count).bigEndian
        withUnsafeBytes(of: &count) { header.append(contentsOf: $0) }
        try writeAll(header)
        try samples.withUnsafeBytes { raw in
            try writeAll(Data(raw))
        }
    }

    public func beginSession() throws {
        lock.lock()
        defer { lock.unlock() }
        endpointDeadline = Date().addingTimeInterval(1)
        clearPending = true
        do {
            try connectSessionIfNeededLocked()
        } catch {
            if shouldWaitForEndpoint(error) { return }
            throw error
        }
    }

    private func connectSessionIfNeededLocked() throws {
        try connectIfNeededLocked()
        if clearPending {
            try writeAll(Data([0x43, 0x4C, 0x45, 0x52, 0, 0, 0, 0]))
            clearPending = false
        }
        endpointDeadline = nil
    }

    private func shouldWaitForEndpoint(_ error: Error) -> Bool {
        guard let endpointDeadline, Date() < endpointDeadline,
              case CodexMicSocketError.connectionFailed(let code) = error else {
            return false
        }
        return code == ENOENT || code == ECONNREFUSED
    }

    private func connectIfNeededLocked() throws {
        guard descriptor < 0 else { return }
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw CodexMicSocketError.pathTooLong
        }
        let newDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard newDescriptor >= 0 else {
            throw CodexMicSocketError.socketCreationFailed(errno)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            socketPath.utf8.withContiguousStorageIfAvailable { source in
                destination.copyBytes(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(newDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(newDescriptor)
            throw CodexMicSocketError.connectionFailed(code)
        }
        descriptor = newDescriptor
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    Darwin.close(descriptor)
                    descriptor = -1
                    throw CodexMicSocketError.writeFailed(code)
                }
                offset += written
            }
        }
    }
}
#endif
