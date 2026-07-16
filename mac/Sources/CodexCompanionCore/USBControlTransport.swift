#if os(macOS)
import Combine
import Darwin
import Foundation

/// Small lock-protected writer used by a background heartbeat. The daemon's
/// UI/main run loop is intentionally optional, whereas USB liveness must keep
/// running even while no Companion window is visible.
private final class USBSerialWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    func attach(_ descriptor: Int32) {
        lock.lock()
        defer { lock.unlock() }
        self.descriptor = descriptor
        // AppleUSBCDC does not assert DTR merely by opening a composite UAC
        // device. Explicitly assert the normal terminal control lines before
        // the first control packet reaches the ESP32.
        var signals = Int32(TIOCM_DTR | TIOCM_RTS)
        _ = Darwin.ioctl(descriptor, UInt(TIOCMBIS), &signals)
    }

    func detach() {
        lock.lock()
        descriptor = -1
        lock.unlock()
    }

    @discardableResult
    func write(_ line: String) -> Bool {
        let bytes = Array(line.utf8)
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return false }
        return bytes.withUnsafeBytes { raw in
            Darwin.write(descriptor, raw.baseAddress, raw.count) == raw.count
        }
    }
}

/// The control sideband of the native UAC microphone.
///
/// Audio is deliberately not carried here: macOS and third-party input methods
/// consume the ESP32 as an ordinary USB Audio Class input. This tiny CDC link
/// only mirrors Codex state and the physical BOOT press/release edge.
public enum USBControlState: Equatable, Sendable {
    case stopped
    case waiting
    case connected(path: String)
    case failed(String)

    public var displayName: String {
        switch self {
        case .stopped: "未启动"
        case .waiting: "等待 USB 控制通道"
        case .connected(let path): "已连接（\(URL(fileURLWithPath: path).lastPathComponent)）"
        case .failed(let detail): "失败：\(detail)"
        }
    }
}

@MainActor
public final class USBControlTransport: ObservableObject {
    @Published public private(set) var state: USBControlState = .stopped

    public var onButton: ((Bool) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?

    /// Keep the CDC descriptor under our own control. `FileHandle.availableData`
    /// can raise an Objective-C exception (`Device not configured`) when macOS
    /// briefly reconfigures a composite UAC+CDC device; that used to terminate
    /// the entire Companion process during a USB transition.
    private var portDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let writer = USBSerialWriter()
    private var activePath: String?
    private var receiveBuffer = Data()
    private var scanTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?

    public init() {}

    public func start() {
        guard scanTimer == nil else { return }
        state = .waiting
        connectIfAvailable()
        scanTimer = makeTimer(every: 1) { [weak self] in self?.connectIfAvailable() }
        heartbeatTimer = makeBackgroundTimer(every: 2) { [writer] in
            _ = writer.write("H:1\n")
        }
    }

    public func stop() {
        scanTimer?.cancel()
        heartbeatTimer?.cancel()
        scanTimer = nil
        heartbeatTimer = nil
        closePort(reportChange: true)
        state = .stopped
    }

    public func send(state deviceState: DeviceState) {
        let value: UInt8
        switch deviceState {
        case .disconnected: value = 0
        case .idle: value = 1
        case .sessionStarting: value = 2
        case .working: value = 3
        case .completed: value = 4
        case .error: value = 5
        case .approvalRequired: value = 6
        case .inputRequired: value = 7
        case .confirmationRequired: value = 8
        case .listening: value = 9
        case .voiceError: value = 10
        case .writing: value = 11
        case .running: value = 12
        }
        sendLine(String(format: "S:%X\\n", value))
    }

    private func connectIfAvailable() {
        guard portDescriptor < 0 else { return }
        guard let path = candidatePaths().first else {
            state = .waiting
            return
        }
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            state = .failed("无法打开 \(URL(fileURLWithPath: path).lastPathComponent)")
            return
        }
        configureRawSerial(descriptor)
        writer.attach(descriptor)
        portDescriptor = descriptor
        activePath = path
        receiveBuffer.removeAll(keepingCapacity: true)
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            // The descriptor is non-blocking and carries only tiny control
            // lines, so handling the read on the main queue is effectively
            // instantaneous. More importantly it keeps this @MainActor
            // transport on one executor; dispatching its closure to a global
            // queue triggers Swift 6's isolation trap during a BOOT edge.
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.readAvailable(from: descriptor)
        }
        readSource = source
        source.resume()
        state = .connected(path: path)
        // A first heartbeat is both the explicit local handshake and the
        // liveness source used by the firmware's six-second safety timeout.
        sendHeartbeat()
        onConnectionChange?(true)
    }

    private func makeTimer(
        every interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            Task { @MainActor in action() }
        }
        timer.resume()
        return timer
    }

    private func makeBackgroundTimer(
        every interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: action)
        timer.resume()
        return timer
    }

    private func candidatePaths() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    private func sendHeartbeat() {
        sendLine("H:1\\n")
    }

    private func sendLine(_ line: String) {
        _ = writer.write(line)
    }

    private func receive(_ data: Data, from descriptor: Int32) {
        guard descriptor == portDescriptor, !data.isEmpty else { return }
        receiveBuffer.append(data)
        while let separator = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer.prefix(upTo: separator)
            receiveBuffer.removeSubrange(...separator)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch line {
            case "B:1":
                FileHandle.standardError.write(Data("[Codex USB] BOOT down\\n".utf8))
                onButton?(true)
            case "B:0":
                FileHandle.standardError.write(Data("[Codex USB] BOOT up\\n".utf8))
                onButton?(false)
            default: break
            }
        }
        if receiveBuffer.count > 128 { receiveBuffer.removeAll(keepingCapacity: true) }
    }

    private func readAvailable(from descriptor: Int32) {
        guard descriptor == portDescriptor else { return }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { raw in
            Darwin.read(descriptor, raw.baseAddress, raw.count)
        }
        if count > 0 {
            receive(Data(bytes.prefix(Int(count))), from: descriptor)
        } else if count == 0 {
            handleReadEnd(from: descriptor)
        } else {
            let error = errno
            // EAGAIN is normal for an event that was drained by an earlier
            // main-queue iteration. Other errors mean the device changed.
            if error != EAGAIN && error != EWOULDBLOCK && error != EINTR {
                handleReadEnd(from: descriptor)
            }
        }
    }

    private func closePort(reportChange: Bool) {
        guard portDescriptor >= 0 else { return }
        let descriptor = portDescriptor
        readSource?.cancel()
        readSource = nil
        writer.detach()
        Darwin.close(descriptor)
        portDescriptor = -1
        activePath = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        if reportChange { onConnectionChange?(false) }
    }

    private func handleReadEnd(from descriptor: Int32) {
        guard descriptor == portDescriptor else { return }
        closePort(reportChange: true)
        state = .waiting
    }

    private func configureRawSerial(_ descriptor: Int32) {
        var options = termios()
        guard Darwin.tcgetattr(descriptor, &options) == 0 else { return }
        Darwin.cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cc.16 = 0 // VMIN: non-blocking reads; the dispatch source drives arrival.
        options.c_cc.17 = 0 // VTIME
        _ = Darwin.tcsetattr(descriptor, TCSANOW, &options)
    }
}
#endif
