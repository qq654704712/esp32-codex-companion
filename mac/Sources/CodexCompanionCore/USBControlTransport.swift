#if os(macOS)
import Combine
import Darwin
import Foundation
import IOKit
import IOKit.serial

struct USBSerialDeviceIdentity: Equatable, Sendable {
    let path: String
    let vendorID: Int?
    let productID: Int?
    let productName: String?
}

/// Restrict the USB sideband to the TinyUSB composite device shipped by this
/// firmware. The ESP32-S3 native USB Serial/JTAG interface also appears as a
/// `cu.usbmodem` device, but opening it with terminal control lines resets the
/// board. Matching only the UAC product prevents the daemon's one-second scan
/// from turning that reset into a permanent reboot loop.
enum USBControlDeviceMatcher {
    static let espressifVendorID = 0x303A
    static let companionUACProductID = 0x8001

    static func accepts(_ device: USBSerialDeviceIdentity) -> Bool {
        device.vendorID == espressifVendorID &&
            device.productID == companionUACProductID
    }
}

enum USBSerialDeviceDiscovery {
    static func devices() -> [USBSerialDeviceIdentity] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [USBSerialDeviceIdentity] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let path = property(kIOCalloutDeviceKey, on: service) as? String,
                  path.hasPrefix("/dev/cu.usbmodem") || path.hasPrefix("/dev/cu.usbserial")
            else { continue }

            devices.append(USBSerialDeviceIdentity(
                path: path,
                vendorID: integerProperty("idVendor", on: service),
                productID: integerProperty("idProduct", on: service),
                productName: ancestorProperty("USB Product Name", on: service) as? String
                    ?? ancestorProperty("kUSBProductString", on: service) as? String
            ))
        }
        return devices.sorted { $0.path < $1.path }
    }

    private static func property(_ key: String, on service: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private static func integerProperty(_ key: String, on service: io_registry_entry_t) -> Int? {
        let value = ancestorProperty(key, on: service)
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func ancestorProperty(_ key: String, on service: io_registry_entry_t) -> Any? {
        IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }
}

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
        // The verified TinyUSB CDC sideband needs DTR before it reports a host
        // connection. RTS is intentionally left untouched: asserting both
        // lines is unsafe for ESP development ports and is unnecessary here.
        var signals = Int32(TIOCM_DTR)
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

/// Line protocol shared by the native USB control sideband and its tests.
/// Every command must end in a real LF byte; sending the two printable
/// characters `\\` and `n` leaves the firmware waiting forever for a line.
enum USBControlProtocol {
    static let heartbeat = "H:1\n"
    static let returnRequest = "K:R"

    static func taskEvent(_ kind: CodexTaskEventKind) -> String {
        kind == .started ? "E:S\n" : "E:D\n"
    }

    static func promptOpen(_ payload: Data) -> String {
        "P:\(payload.base64EncodedString())\n"
    }

    static let promptClose = "C:P\n"

    static func weather(_ payload: Data) -> String {
        "W:\(payload.base64EncodedString())\n"
    }

    static func weatherConfiguration(
        _ payload: DeviceWeatherConfigurationPayload
    ) -> String {
        "G:\(payload.enabled ? 1 : 0):\(payload.usesCelsius ? 1 : 0):\(payload.refreshMinutes)\n"
    }

    static func state(_ deviceState: DeviceState) -> String {
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
        return String(format: "S:%X\n", value)
    }
}

enum USBButtonEdgeAction: Equatable {
    case down
    case up
}

/// Accepts a physical USB button edge only when it changes the current state.
/// The firmware intentionally mirrors BOOT over HID and CDC, so both callbacks
/// can arrive for the same press once macOS has approved the HID interface.
/// A short release-to-rearm window also absorbs the board button's occasional
/// mechanical rebound, which otherwise looks like a brand-new voice session.
struct USBButtonEdgeDeduplicator {
    static let rearmInterval: TimeInterval = 0.35

    private(set) var isDown = false
    private var rearmAfter: TimeInterval = 0
    private var suppressingPress = false

    mutating func action(
        for nextIsDown: Bool,
        at uptime: TimeInterval
    ) -> USBButtonEdgeAction? {
        guard nextIsDown != isDown else { return nil }
        isDown = nextIsDown
        if nextIsDown {
            guard uptime >= rearmAfter else {
                suppressingPress = true
                return nil
            }
            return .down
        }
        if suppressingPress {
            suppressingPress = false
            return nil
        }
        rearmAfter = uptime + Self.rearmInterval
        return .up
    }

    mutating func reset() {
        isDown = false
        rearmAfter = 0
        suppressingPress = false
    }
}

@MainActor
public final class USBControlTransport: ObservableObject {
    @Published public private(set) var state: USBControlState = .stopped

    public var onButton: ((Bool) -> Void)?
    public var onSubmit: (() -> Void)?
    public var onPromptSelection: ((DeviceOptionSelection, Bool) -> Void)?
    public var onWeatherConfiguration: ((DeviceWeatherConfigurationPayload) -> Void)?
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
            _ = writer.write(USBControlProtocol.heartbeat)
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
        sendLine(USBControlProtocol.state(deviceState))
    }

    public func send(taskEvent kind: CodexTaskEventKind) {
        sendLine(USBControlProtocol.taskEvent(kind))
    }

    public func sendPrompt(_ payload: Data) {
        sendLine(USBControlProtocol.promptOpen(payload))
    }

    public func closePrompt() {
        sendLine(USBControlProtocol.promptClose)
    }

    public func sendWeather(_ payload: Data) {
        sendLine(USBControlProtocol.weather(payload))
    }

    public func sendWeatherConfiguration(_ payload: DeviceWeatherConfigurationPayload) {
        sendLine(USBControlProtocol.weatherConfiguration(payload))
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
        USBSerialDeviceDiscovery.devices()
            .filter(USBControlDeviceMatcher.accepts)
            .map(\.path)
    }

    private func sendHeartbeat() {
        sendLine(USBControlProtocol.heartbeat)
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
                FileHandle.standardError.write(Data("[Codex USB] BOOT down\n".utf8))
                onButton?(true)
            case "B:0":
                FileHandle.standardError.write(Data("[Codex USB] BOOT up\n".utf8))
                onButton?(false)
            case USBControlProtocol.returnRequest:
                FileHandle.standardError.write(Data("[Codex USB] Return requested\n".utf8))
                onSubmit?()
            default:
                let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                if fields.count == 4, fields[0] == "O",
                   let promptID = UInt32(fields[1]), let option = UInt8(fields[2]),
                   let hold = UInt8(fields[3]), hold <= 1 {
                    onPromptSelection?(.init(promptID: promptID, optionIndex: option), hold == 1)
                } else if fields.count == 4, fields[0] == "G",
                          let enabled = UInt8(fields[1]), enabled <= 1,
                          let usesCelsius = UInt8(fields[2]), usesCelsius <= 1,
                          let refresh = UInt8(fields[3]), [15, 30, 60].contains(refresh) {
                    onWeatherConfiguration?(.init(
                        enabled: enabled == 1,
                        usesCelsius: usesCelsius == 1,
                        refreshMinutes: refresh
                    ))
                }
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
