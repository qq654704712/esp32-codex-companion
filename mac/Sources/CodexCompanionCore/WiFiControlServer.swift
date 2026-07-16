#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Network

/// The Mac-side, Wi-Fi daily-use control endpoint. Discovery is intentionally
/// separate (Bonjour only advertises this listener); a client must still prove
/// it has the recovery-pairing secret before it can send a control envelope.
public final class WiFiControlServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case listening(port: UInt16)
        case connected
        case failed(String)
    }

    public static let defaultPort: UInt16 = 49_152
    public static let discoveryPort: UInt16 = 49_153
    private static let discoveryRequest = Data("CCDISC2".utf8)
    private static let discoveryResponse = Data("CCHOST2".utf8)

    public var onStateChange: (@Sendable (State) -> Void)?
    public var onControlMessage: (@Sendable (Data) -> Void)?

    private let queue = DispatchQueue(label: "com.codexcompanion.wifi-control")
    private let pairingSecret: Data
    private let hostIdentity: CompanionHostIdentity
    private let requestedPort: UInt16
    private let requestedDiscoveryPort: UInt16
    private var listener: NWListener?
    private var discoverySocket: Int32 = -1
    private var discoverySource: DispatchSourceRead?
    /// Keep a just-accepted connection alive until its CCH2 handshake either
    /// authenticates or fails. Without this reference, the receive closure's
    /// weak capture can release the object before the first packet arrives.
    private var pendingConnection: Connection?
    private var activeConnection: Connection?
    private var state: State = .stopped

    public init(
        pairingSecret: Data,
        hostIdentity: CompanionHostIdentity,
        port: UInt16 = defaultPort,
        discoveryPort: UInt16 = WiFiControlServer.discoveryPort
    ) throws {
        guard pairingSecret.count == SessionKeyDeriver.pairingSecretByteCount else {
            throw WiFiWireCodecError.invalidKeyLength
        }
        guard !hostIdentity.id.isEmpty, !hostIdentity.publicKeyFingerprint.isEmpty else {
            throw WiFiWireCodecError.invalidFrame
        }
        self.pairingSecret = pairingSecret
        self.hostIdentity = hostIdentity
        requestedPort = port
        requestedDiscoveryPort = discoveryPort
    }

    public var isConnected: Bool {
        queue.sync { activeConnection != nil }
    }

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    /// The inner v1 ControlEnvelope remains signed with the pairing secret.
    /// The outer CCW2 frame adds per-session encryption and replay protection.
    public func sendControl(_ payload: Data) {
        queue.async { [weak self] in self?.activeConnection?.send(payload: payload) }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        do {
            let port = try NWEndpoint.Port(rawValue: requestedPort).unwrap(or: WiFiWireCodecError.invalidFrame)
            let listener = try NWListener(using: .tcp, on: port)
            listener.service = NWListener.Service(
                name: "Codex Companion \(hostIdentity.id)",
                type: "_codex-companion._tcp",
                domain: "local.",
                txtRecord: NetService.data(fromTXTRecord: [
                    "v": Data("2".utf8),
                    "host": Data(hostIdentity.id.utf8),
                    "fp": Data(hostIdentity.publicKeyFingerprint.utf8),
                ])
            )
            let server = self
            listener.stateUpdateHandler = { [weak server] listenerState in
                guard let server else { return }
                server.queue.async { server.handleListenerState(listenerState) }
            }
            listener.newConnectionHandler = { [weak server] connection in
                guard let server else { return }
                server.queue.async { server.accept(connection) }
            }
            listener.serviceRegistrationUpdateHandler = { change in
                FileHandle.standardError.write(
                    Data("[Codex Wi-Fi] Bonjour registration: \(change)\n".utf8)
                )
            }
            self.listener = listener
            listener.start(queue: queue)
            startUDPDiscoveryOnQueue()
        } catch {
            transition(.failed(String(describing: error)))
        }
    }

    private func startUDPDiscoveryOnQueue() {
        guard discoverySource == nil else { return }
        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            FileHandle.standardError.write(
                Data("[Codex Wi-Fi] UDP discovery socket unavailable: \(String(cString: strerror(errno)))\n".utf8)
            )
            return
        }
        var reuse = Int32(1)
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var broadcast = Int32(1)
        _ = withUnsafePointer(to: &broadcast) {
            setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedDiscoveryPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(socketFD)
            FileHandle.standardError.write(
                Data("[Codex Wi-Fi] UDP discovery bind unavailable: \(message)\n".utf8)
            )
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.receiveDiscoveryDatagrams() }
        source.setCancelHandler { Darwin.close(socketFD) }
        discoverySocket = socketFD
        discoverySource = source
        source.resume()
    }

    private func receiveDiscoveryDatagrams() {
        guard discoverySocket >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { bufferBytes in
                withUnsafeMutablePointer(to: &source) { sourcePointer in
                    sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(discoverySocket, bufferBytes.baseAddress, bufferBytes.count, 0,
                                        $0, &sourceLength)
                    }
                }
            }
            if received <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            guard Data(buffer.prefix(Int(received))) == Self.discoveryRequest else { continue }
            FileHandle.standardError.write(Data("[Codex Wi-Fi] UDP discovery request received\n".utf8))
            Self.discoveryResponse.withUnsafeBytes { responseBytes in
                withUnsafePointer(to: &source) { sourcePointer in
                    sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = Darwin.sendto(discoverySocket, responseBytes.baseAddress,
                                           responseBytes.count, 0, $0, sourceLength)
                    }
                }
            }
        }
    }

    private func stopOnQueue() {
        activeConnection?.cancel()
        pendingConnection?.cancel()
        activeConnection = nil
        pendingConnection = nil
        if let source = discoverySource {
            discoverySource = nil
            discoverySocket = -1
            source.cancel()
        }
        listener?.cancel()
        listener = nil
        transition(.stopped)
    }

    private func handleListenerState(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            let actualPort = listener?.port?.rawValue ?? requestedPort
            transition(.listening(port: actualPort))
        case .failed(let error):
            listener?.cancel()
            listener = nil
            transition(.failed(error.localizedDescription))
        case .cancelled:
            if listener == nil { transition(.stopped) }
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        // A companion is one physical device. Replacing an old TCP connection
        // is safer than accidentally applying two concurrent approval streams.
        activeConnection?.cancel()
        pendingConnection?.cancel()
        let connection = Connection(
            nwConnection: nwConnection,
            pairingSecret: pairingSecret,
            onAuthenticated: { [weak self] connection in
                guard let self else { return }
                self.queue.async {
                    if self.pendingConnection === connection {
                        self.pendingConnection = nil
                    }
                    self.activeConnection = connection
                    self.transition(.connected)
                }
            },
            onControl: { [weak self] payload in
                self?.onControlMessage?(payload)
            },
            onClosed: { [weak self] connection in
                guard let self else { return }
                self.queue.async {
                    if self.pendingConnection === connection {
                        self.pendingConnection = nil
                    }
                    if self.activeConnection === connection {
                        self.activeConnection = nil
                        if let port = self.listener?.port?.rawValue {
                            self.transition(.listening(port: port))
                        } else {
                            self.transition(.stopped)
                        }
                    }
                }
            }
        )
        pendingConnection = connection
        nwConnection.start(queue: queue)
        connection.begin()
    }

    private func transition(_ newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}

private final class Connection: @unchecked Sendable {
    private let nwConnection: NWConnection
    private let pairingSecret: Data
    private let onAuthenticated: @Sendable (Connection) -> Void
    private let onControl: @Sendable (Data) -> Void
    private let onClosed: @Sendable (Connection) -> Void
    private var framer = WiFiTCPFramer()
    private var sessionKey: Data?
    private var sessionID: UInt64 = 0
    private var inboundReplay = WiFiReplayWindow()
    private var outboundSequence: UInt32 = 0
    private var closed = false

    init(
        nwConnection: NWConnection,
        pairingSecret: Data,
        onAuthenticated: @escaping @Sendable (Connection) -> Void,
        onControl: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable (Connection) -> Void
    ) {
        self.nwConnection = nwConnection
        self.pairingSecret = pairingSecret
        self.onAuthenticated = onAuthenticated
        self.onControl = onControl
        self.onClosed = onClosed
    }

    func begin() {
        nwConnection.receive(
            minimumIncompleteLength: WiFiSessionHandshake.encodedByteCount,
            maximumLength: WiFiSessionHandshake.encodedByteCount
        ) { [weak self] data, _, complete, error in
            guard let self else { return }
            guard error == nil, !complete, let data,
                  data.count == WiFiSessionHandshake.encodedByteCount else {
                self.close()
                return
            }
            do {
                let device = try WiFiSessionHandshake.decode(data, pairingSecret: self.pairingSecret)
                guard device.role == .device else { throw WiFiWireCodecError.invalidFrame }
                let host = try WiFiSessionHandshake(
                    role: .host,
                    nonce: ApplicationKeyManager.generate()
                )
                let response = try host.encode(pairingSecret: self.pairingSecret)
                let nonce = try WiFiSessionHandshake.sessionNonce(device: device, host: host)
                self.sessionKey = try SessionKeyDeriver.derive(
                    pairingSecret: self.pairingSecret,
                    sessionNonce: nonce
                ).controlKey
                self.sessionID = try WiFiSessionHandshake.sessionID(device: device, host: host)
                self.nwConnection.send(content: response, completion: .contentProcessed { [weak self] error in
                    guard error == nil else { self?.close(); return }
                    guard let self else { return }
                    self.onAuthenticated(self)
                    self.receiveControl()
                })
            } catch {
                self.close()
            }
        }
    }

    func send(payload: Data) {
        guard let sessionKey, !closed else { return }
        outboundSequence &+= 1
        let envelope = WiFiControlEnvelope(
            sessionID: sessionID,
            sequence: outboundSequence,
            timestampMs: UInt64(ProcessInfo.processInfo.systemUptime * 1_000),
            payload: payload
        )
        guard let packet = try? WiFiWireCodec.encodeControl(envelope, key: sessionKey),
              let framed = try? WiFiTCPFramer.encode(packet) else { return }
        nwConnection.send(content: framed, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func receiveControl() {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 2_048) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data else { self.close(); return }
            do {
                for packet in try self.framer.append(data) {
                    guard let sessionKey else { throw WiFiWireCodecError.invalidFrame }
                    let envelope = try WiFiWireCodec.decodeControl(packet, key: sessionKey)
                    guard envelope.sessionID == self.sessionID else { throw WiFiWireCodecError.invalidFrame }
                    _ = try self.inboundReplay.accept(
                        sequence: envelope.sequence,
                        sessionID: envelope.sessionID
                    )
                    self.onControl(envelope.payload)
                }
            } catch {
                self.close()
                return
            }
            if complete { self.close() } else { self.receiveControl() }
        }
    }

    func cancel() { close() }

    private func close() {
        guard !closed else { return }
        closed = true
        nwConnection.cancel()
        onClosed(self)
    }
}

private extension Optional where Wrapped == NWEndpoint.Port {
    func unwrap(or error: Error) throws -> NWEndpoint.Port {
        guard let self else { throw error }
        return self
    }
}
#endif
