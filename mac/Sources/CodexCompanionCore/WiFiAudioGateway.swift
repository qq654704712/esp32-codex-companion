#if os(macOS)
import Darwin
import Foundation

public struct WiFiAudioDiagnostics: Equatable, Sendable {
    public var received = 0
    public var lost = 0
    public var late = 0
    public var replayed = 0
    public var authenticationFailures = 0
    public var sourceRejected = 0
    public var rebuffered = 0
    public var recoverableStalls = 0
    public var longestGapMs = 0.0
    public var maximumJitterMs = 0.0
    public var maximumSourceFrameIntervalMs = 0.0
    public var maximumNetworkVariationMs = 0.0
    public var firstOutputLatencyMs: Double?
}

public enum WiFiAudioGatewayError: Error, Equatable {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case nonBlockingSetupFailed(Int32)
    case invalidRemoteAddress
}

/// Authenticated UDP PCM receiver. All mutable state, decryption, playout and
/// sink writes live on one queue so the TCP control path is never blocked by
/// audio work.
public final class WiFiAudioGateway: @unchecked Sendable {
    public static let defaultPort: UInt16 = 49_154
    public static let frameDuration: TimeInterval = 0.020
    public static let jitterBufferDuration: TimeInterval = 0.060
    public static let prebufferDuration: TimeInterval = 0.100
    public static let stallDiagnosticDuration: TimeInterval = 0.500

    public var onFatalError: (@Sendable (String) -> Void)?
    public var onAuthenticatedActivity: (@Sendable () -> Void)?
    public var onRecoverableStallChange: (@Sendable (Bool) -> Void)?

    private enum PTTState {
        case idle
        case active
        case draining(until: TimeInterval)
    }

    private struct BufferedFrame {
        let frame: WiFiAudioFrame
        let arrival: TimeInterval
    }

    private let sink: FloatAudioSink
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.codexcompanion.wifi-audio", qos: .userInitiated)
    private let automaticPlayout: Bool
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var playoutTimer: DispatchSourceTimer?
    private var session: WiFiAuthenticatedSession?
    private var remoteAddress: UInt32?
    private var replayWindow = WiFiReplayWindow()
    private var pttState: PTTState = .idle
    private var pttStartedAt: TimeInterval?
    private var lastValidArrival: TimeInterval?
    private var previousArrival: TimeInterval?
    private var previousFrameSequence: UInt32?
    private var previousFrameTimestampMs: UInt64?
    private var prebuffer: [UInt32: BufferedFrame] = [:]
    private var frames: [UInt32: BufferedFrame] = [:]
    private var expectedSequence: UInt32?
    private var firstBufferedAt: TimeInterval?
    private var playoutStarted = false
    private var stallReported = false
    private var resampler = LinearResampler16kTo48k()
    private var diagnostics = WiFiAudioDiagnostics()

    public init(
        sink: FloatAudioSink,
        port: UInt16 = WiFiAudioGateway.defaultPort,
        automaticPlayout: Bool = true
    ) {
        self.sink = sink
        self.port = port
        self.automaticPlayout = automaticPlayout
    }

    deinit {
        playoutTimer?.cancel()
        if let readSource {
            readSource.cancel()
        } else if socketFD >= 0 {
            Darwin.close(socketFD)
        }
    }

    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    public func stop() {
        queue.sync { stopOnQueue() }
    }

    public func configure(session newSession: WiFiAuthenticatedSession?) throws {
        try queue.sync {
            resetSessionState()
            guard let newSession else { return }
            var address = in_addr()
            guard inet_pton(AF_INET, newSession.remoteIPv4, &address) == 1 else {
                throw WiFiAudioGatewayError.invalidRemoteAddress
            }
            session = newSession
            remoteAddress = address.s_addr
        }
    }

    public func beginPTT() {
        queue.sync { beginPTTOnQueue(now: Self.now()) }
    }

    public func endPTT(postRollMs: UInt32 = 200) {
        queue.sync {
            guard case .active = pttState else { return }
            pttState = .draining(
                until: Self.now() + TimeInterval(postRollMs) / 1_000
            )
        }
    }

    public func cancelPTT() {
        queue.sync { resetPTTState(keepPrebuffer: false) }
    }

    public func diagnosticsSnapshot() -> WiFiAudioDiagnostics {
        queue.sync { diagnostics }
    }

    public var isSessionReady: Bool {
        queue.sync { session != nil && remoteAddress != nil && readSource != nil }
    }

    private func startOnQueue() throws {
        guard readSource == nil else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw WiFiAudioGatewayError.socketCreationFailed(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw WiFiAudioGatewayError.bindFailed(code)
        }
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw WiFiAudioGatewayError.nonBlockingSetupFailed(code)
        }
        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainDatagrams() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()

        if automaticPlayout {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + Self.frameDuration,
                repeating: Self.frameDuration,
                leeway: .milliseconds(2)
            )
            timer.setEventHandler { [weak self] in
                self?.playoutTick(now: Self.now())
            }
            playoutTimer = timer
            timer.resume()
        }
    }

    private func stopOnQueue() {
        resetSessionState()
        playoutTimer?.cancel()
        playoutTimer = nil
        if let source = readSource {
            readSource = nil
            socketFD = -1
            source.cancel()
        }
    }

    private func drainDatagrams() {
        guard socketFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 1_024)
        while true {
            var sourceAddress = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = bytes.withUnsafeMutableBytes { buffer in
                withUnsafeMutablePointer(to: &sourceAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(socketFD, buffer.baseAddress, buffer.count, 0,
                                        $0, &sourceLength)
                    }
                }
            }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            if received == 0 { return }
            ingest(
                packet: Data(bytes.prefix(Int(received))),
                sourceAddress: sourceAddress.sin_addr.s_addr,
                arrival: Self.now()
            )
        }
    }

    private func ingest(packet: Data, sourceAddress: UInt32, arrival: TimeInterval) {
        guard let session, let remoteAddress, sourceAddress == remoteAddress else {
            diagnostics.sourceRejected += 1
            return
        }
        let frame: WiFiAudioFrame
        do {
            frame = try WiFiWireCodec.decodeAudio(packet, key: session.audioKey)
            guard frame.sessionID == session.sessionID else {
                diagnostics.authenticationFailures += 1
                return
            }
            _ = try replayWindow.accept(sequence: frame.sequence, sessionID: frame.sessionID)
        } catch WiFiWireCodecError.replayedSequence {
            diagnostics.replayed += 1
            return
        } catch {
            diagnostics.authenticationFailures += 1
            return
        }

        diagnostics.received += 1
        lastValidArrival = arrival
        onAuthenticatedActivity?()
        if stallReported {
            stallReported = false
            onRecoverableStallChange?(false)
        }
        let buffered = BufferedFrame(frame: frame, arrival: arrival)
        switch pttState {
        case .idle:
            prebuffer[frame.sequence] = buffered
            prebuffer = prebuffer.filter { arrival - $0.value.arrival <= Self.prebufferDuration }
            if prebuffer.count > 5,
               let oldest = prebuffer.min(by: { $0.value.arrival < $1.value.arrival })?.key {
                prebuffer.removeValue(forKey: oldest)
            }
        case .active, .draining:
            recordTiming(buffered)
            enqueue(buffered)
        }
    }

    private func beginPTTOnQueue(now: TimeInterval) {
        resetPTTState(keepPrebuffer: true)
        // Diagnostics describe exactly one physical PTT. Session-level replay
        // state remains independent and is reset only by configure(session:).
        diagnostics = WiFiAudioDiagnostics()
        pttState = .active
        pttStartedAt = now
        lastValidArrival = nil
        let recent = prebuffer.values
            .filter { now - $0.arrival <= Self.prebufferDuration }
            .sorted { $0.frame.sequence < $1.frame.sequence }
        prebuffer.removeAll(keepingCapacity: true)
        for frame in recent {
            diagnostics.received += 1
            lastValidArrival = max(lastValidArrival ?? 0, frame.arrival)
            recordTiming(frame)
            enqueue(frame)
        }
    }

    private func recordTiming(_ buffered: BufferedFrame) {
        if let previousArrival {
            let arrivalIntervalMs = (buffered.arrival - previousArrival) * 1_000
            diagnostics.maximumJitterMs = max(
                diagnostics.maximumJitterMs,
                abs(arrivalIntervalMs - Self.frameDuration * 1_000)
            )
            diagnostics.longestGapMs = max(diagnostics.longestGapMs, arrivalIntervalMs)
            if let previousFrameSequence,
               let previousFrameTimestampMs,
               buffered.frame.sequence > previousFrameSequence,
               buffered.frame.timestampMs >= previousFrameTimestampMs {
                let sequenceDelta = Double(buffered.frame.sequence - previousFrameSequence)
                let sourceIntervalMs = Double(buffered.frame.timestampMs - previousFrameTimestampMs)
                diagnostics.maximumSourceFrameIntervalMs = max(
                    diagnostics.maximumSourceFrameIntervalMs,
                    sourceIntervalMs / sequenceDelta
                )
                diagnostics.maximumNetworkVariationMs = max(
                    diagnostics.maximumNetworkVariationMs,
                    abs(arrivalIntervalMs - sourceIntervalMs)
                )
            }
        }
        previousArrival = buffered.arrival
        previousFrameSequence = buffered.frame.sequence
        previousFrameTimestampMs = buffered.frame.timestampMs
    }

    private func enqueue(_ buffered: BufferedFrame) {
        if let expectedSequence, buffered.frame.sequence < expectedSequence {
            diagnostics.late += 1
            return
        }
        guard frames.count < 64 else {
            diagnostics.late += 1
            return
        }
        frames[buffered.frame.sequence] = buffered
        firstBufferedAt = min(firstBufferedAt ?? buffered.arrival, buffered.arrival)
    }

    private func playoutTick(now: TimeInterval) {
        switch pttState {
        case .idle:
            return
        case .draining(let deadline) where now >= deadline:
            resetPTTState(keepPrebuffer: false)
            return
        case .active, .draining:
            break
        }
        let reference = lastValidArrival ?? pttStartedAt
        if let reference, now - reference >= Self.stallDiagnosticDuration,
           !stallReported {
            // BOOT is the authority for the session boundary. A UDP gap is a
            // recoverable transport condition: retain the held shortcut and
            // rebuffer when packets resume instead of synthesizing PTT_UP.
            stallReported = true
            diagnostics.recoverableStalls += 1
            onRecoverableStallChange?(true)
        }
        if !playoutStarted {
            guard let firstBufferedAt,
                  frames.count >= 3 || now - firstBufferedAt >= Self.jitterBufferDuration,
                  let firstSequence = frames.keys.min() else { return }
            expectedSequence = firstSequence
            playoutStarted = true
        }
        guard let sequence = expectedSequence else { return }
        let samples: [Int16]
        if let buffered = frames.removeValue(forKey: sequence) {
            samples = Self.decodePCM16LE(buffered.frame.pcm16LE)
        } else if frames.keys.contains(where: { $0 > sequence }) {
            // A later authenticated frame proves that this one was lost.
            // Preserve the media timeline with exactly one silent frame.
            diagnostics.lost += 1
            samples = [Int16](repeating: 0, count: WiFiAudioFrame.sampleCount)
        } else {
            // No future frame exists yet, so this is network jitter rather
            // than proven packet loss. Hold the expected sequence and rebuild
            // the 60 ms playout waterline. Advancing here makes every frame in
            // a delayed UDP batch look late and creates a self-sustaining run
            // of synthetic silence.
            diagnostics.rebuffered += 1
            playoutStarted = false
            firstBufferedAt = nil
            return
        }
        expectedSequence = sequence &+ 1
        do {
            try sink.write(samples: resampler.process(samples))
            if diagnostics.firstOutputLatencyMs == nil, let pttStartedAt {
                diagnostics.firstOutputLatencyMs = (now - pttStartedAt) * 1_000
            }
        } catch {
            resetPTTState(keepPrebuffer: false)
            onFatalError?("Codex Mic write failed: \(error)")
        }
    }

    private func resetSessionState() {
        session = nil
        remoteAddress = nil
        replayWindow.reset()
        previousArrival = nil
        previousFrameSequence = nil
        previousFrameTimestampMs = nil
        diagnostics = WiFiAudioDiagnostics()
        resetPTTState(keepPrebuffer: false)
    }

    private func resetPTTState(keepPrebuffer: Bool) {
        pttState = .idle
        pttStartedAt = nil
        lastValidArrival = nil
        previousArrival = nil
        previousFrameSequence = nil
        previousFrameTimestampMs = nil
        frames.removeAll(keepingCapacity: true)
        if !keepPrebuffer { prebuffer.removeAll(keepingCapacity: true) }
        expectedSequence = nil
        firstBufferedAt = nil
        playoutStarted = false
        stallReported = false
        resampler = LinearResampler16kTo48k()
    }

    private static func decodePCM16LE(_ data: Data) -> [Int16] {
        var output: [Int16] = []
        output.reserveCapacity(WiFiAudioFrame.sampleCount)
        for offset in stride(from: 0, to: data.count, by: 2) {
            let value = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            output.append(Int16(bitPattern: value))
        }
        return output
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // Deterministic hooks used by the package tests; they exercise the same
    // authenticated ingestion and playout paths as the UDP socket.
    func ingestForTesting(packet: Data, sourceIPv4: String, at arrival: TimeInterval) throws {
        try queue.sync {
            var address = in_addr()
            guard inet_pton(AF_INET, sourceIPv4, &address) == 1 else {
                throw WiFiAudioGatewayError.invalidRemoteAddress
            }
            ingest(packet: packet, sourceAddress: address.s_addr, arrival: arrival)
        }
    }

    func beginPTTForTesting(at time: TimeInterval) {
        queue.sync { beginPTTOnQueue(now: time) }
    }

    func endPTTForTesting(at time: TimeInterval, postRollMs: UInt32 = 200) {
        queue.sync {
            guard case .active = pttState else { return }
            pttState = .draining(until: time + TimeInterval(postRollMs) / 1_000)
        }
    }

    func playoutForTesting(at time: TimeInterval) {
        queue.sync { playoutTick(now: time) }
    }
}
#endif
