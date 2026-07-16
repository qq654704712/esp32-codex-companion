#if os(macOS)
import AppKit
import Combine
import CryptoKit
import Foundation

private final class RemoteAudioSession: AudioStreaming {
    func start(preRollMs: UInt32) throws { _ = preRollMs }
    func stop(postRollMs: UInt32) { _ = postRollMs }
    func cancel() {}
}

@MainActor
public final class CompanionService: ObservableObject {
    @Published public private(set) var bleState: CompanionBLECentral.State = .disconnected
    @Published public private(set) var codexMicAvailable = false
    @Published public private(set) var accessibilityAvailable = false
    @Published public private(set) var codexComposerAvailable = false
    /// The companion window cannot inspect the Codex editor while it is frontmost.
    /// Keep the latest check made while Codex itself owned the foreground instead
    /// of replacing it with a false result as soon as the user opens this window.
    @Published public private(set) var codexComposerCheckedAt: Date?
    @Published public private(set) var observedCodexState: DeviceState = .idle
    @Published public private(set) var observedCodexDetail = "等待 Codex 会话"
    @Published public private(set) var usbControlState: USBControlState = .stopped
    @Published public private(set) var activeVoiceProfileName: String?
    @Published public private(set) var lastVoiceError: String?
    @Published public private(set) var isRunning = false
    private let sink: CodexMicSocketClient
    private let ble: CompanionBLECentral
    private let profileStore: VoiceProfileStore
    private let inputSources = InputSourceCatalog()
    private let accessibility = CodexAccessibilityInspector()
    private let approvals = CodexApprovalAccessibilityBridge()
    private let ptt: PTTController
    private let hookInbox = HookInbox()
    private let usbControl = USBControlTransport()
    private let usbHIDPTT = USBHIDPTTMonitor()
    private var rolloutMonitor = CodexRolloutMonitor()
    private let quotaClient = CodexAppServerClient()
    private let keyManager = ApplicationKeyManager()
    private var timers: [DispatchSourceTimer] = []
    private var observers: [NSObjectProtocol] = []
    private var bleInboundGuard = SequenceGuard()
    private var wifiInboundGuard = SequenceGuard()
    private var peerLiveness = PeerLiveness(timeout: 6)
    private var outboundSequence: UInt32 = 0
    private var savedInputSourceID: String?
    private var shouldRestoreInputSource = false
    private var activeProfile: VoiceShortcutProfile?
    private var latestQuota: QuotaSnapshot?
    private var quotaRefreshInFlight = false
    private var pendingApprovalUntil: Date?
    private var activePrompt: DevicePromptPayload?
    private var activePromptRevision: UInt64?
    private var nextPromptID: UInt32 = 0
    private var controlReducer = CompanionControlReducer()
    private var started = false
    private var runtimeLease: CompanionRuntimeLease?
    private var pairingSecret: Data?
    private var wifiServer: WiFiControlServer?
    private var wifiState: WiFiControlServer.State = .stopped

    private enum ControlTransport { case ble, wifi }

    public init(profileStore: VoiceProfileStore = VoiceProfileStore()) {
        let sink = CodexMicSocketClient()
        self.sink = sink
        ble = CompanionBLECentral(audioSink: sink)
        self.profileStore = profileStore
        ptt = PTTController(
            audio: RemoteAudioSession(),
            route: CodexMicRouteManager(),
            keys: CGEventShortcutEmitter()
        )
    }

    public func start() {
        guard !started else { return }
        guard let lease = CompanionRuntimeLease.acquire() else {
            lastVoiceError = "后台 Companion 已在运行；此窗口仅用于配置与查看状态"
            return
        }
        runtimeLease = lease
        started = true
        isRunning = true
        refreshHostStatus()
        // Request consent from the packaged App identity on first launch. The
        // daemon now lives inside CodexCompanion.app, so this resolves to the
        // exact entry the user can enable in System Settings.
        if !accessibilityAvailable {
            CGEventShortcutEmitter.requestAccessibilityPermission()
        }
        usbControl.onButton = { [weak self] isDown in
            guard let self else { return }
            if isDown {
                self.beginVoiceSession(usingNativeUSBMic: true)
            } else {
                self.endVoiceSession()
            }
        }
        usbHIDPTT.onButton = { [weak self] isDown in
            guard let self else { return }
            if isDown {
                self.beginVoiceSession(usingNativeUSBMic: true)
            } else {
                self.endVoiceSession()
            }
        }
        usbHIDPTT.start()
        usbControl.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.usbControlState = self.usbControl.state
            if connected {
                self.sendState(self.controlReducer.currentSnapshot()?.state ?? self.observedCodexState)
            }
        }
        usbControl.start()
        usbControlState = usbControl.state
        startWiFiControl()
        ble.onStateChange = { [weak self] state in
            guard let self else { return }
            self.bleState = state
            if state == .connected {
                self.bleInboundGuard.reset()
                self.peerLiveness.markAuthenticatedInput(at: ProcessInfo.processInfo.systemUptime)
                self.refreshQuota(force: true)
                // A reconnect must receive the current state rather than an
                // invented idle transition. This keeps a running task or an
                // open approval accurate after the radio recovers.
                self.sendState(self.controlReducer.currentSnapshot()?.state ?? .idle)
            } else {
                self.peerLiveness.reset()
                if self.ptt.state != .idle {
                    // A lost link must never leave a synthesized modifier held
                    // or Codex Mic selected as the system default input.
                    self.failVoiceSession()
                }
            }
        }
        ble.onControlMessage = { [weak self] data in
            guard let self, let key = self.ble.sharedKey else { return }
            self.handleControl(data, key: key, transport: .ble)
        }
        ble.onAudioError = { [weak self] error in
            FileHandle.standardError.write(
                Data("[Codex Voice] audio write failed: \(String(describing: error))\n".utf8)
            )
            self?.lastVoiceError = String(describing: error)
            self?.failVoiceSession()
        }
        ble.onInboundActivity = { [weak self] in
            self?.peerLiveness.markAuthenticatedInput(
                at: ProcessInfo.processInfo.systemUptime
            )
        }
        ble.start()
        schedule(every: 0.05) { [weak self] in
            self?.drainHooks()
            self?.pollApprovalDialog()
        }
        schedule(every: 0.3) { [weak self] in self?.pollCodexRollout() }
        schedule(every: 2) { [weak self] in
            guard let self else { return }
            let now = Int64(Date().timeIntervalSince1970)
            let fresh = self.latestQuota.map { now - $0.updatedAt <= 120 } ?? false
            self.send(type: .heartbeat, payload: DevicePayloadCodec.heartbeat(quotaFresh: fresh))
        }
        schedule(every: 1) { [weak self] in
            guard let self, (self.ble.state == .connected || self.wifiServer?.isConnected == true),
                  self.peerLiveness.isExpired(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.peerLiveness.reset()
            self.failVoiceSession()
            self.ble.reconnect()
        }
        schedule(every: 60) { [weak self] in self?.refreshQuota(force: false) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota(force: true) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHostStatus() }
        })
        refreshQuota(force: true)
    }

    public func stop() {
        guard started else { return }
        started = false
        isRunning = false
        timers.forEach { $0.cancel() }
        timers.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        ptt.cancel()
        restoreInputSource()
        usbControl.stop()
        usbControlState = .stopped
        ble.stop()
        wifiServer?.stop()
        wifiServer = nil
        pairingSecret = nil
        sink.disconnect()
        bleState = .disconnected
        runtimeLease?.release()
        runtimeLease = nil
    }

    public func reconnect() {
        guard started else { return }
        lastVoiceError = nil
        ble.reconnect()
    }

    public func refreshHostStatus() {
        accessibilityAvailable = CGEventShortcutEmitter.isAccessibilityTrusted
        codexMicAvailable = (try? CodexMicRouteManager().preferredInputDevice()) != nil
        // Checking here while Companion is frontmost can only observe Companion's
        // own controls. Only replace the editor status when the Codex app is the
        // active application; this makes the dashboard an honest latest reading.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == CodexInteractionGate.bundleIdentifier else { return }
        codexComposerAvailable = accessibility.canStartVoiceInput()
        codexComposerCheckedAt = Date()
    }

    public func requestAccessibilityPermission() {
        CGEventShortcutEmitter.requestAccessibilityPermission()
        // TCC updates asynchronously after the user responds to its system
        // panel. Refresh shortly afterwards so the dashboard does not require
        // relaunching the companion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshHostStatus()
        }
    }

    public func runtimeStatus() -> CompanionRuntimeStatus {
        CompanionRuntimeStatus(
            lifecycle: isRunning ? .running : .stopped,
            bleDescription: runtimeBLEDescription,
            wifiDescription: runtimeWiFiDescription,
            // Read the transport directly here. The visible app is normally
            // a status-only client while the launch agent owns this service,
            // so this file is the authoritative USB connection report.
            usbDescription: usbControl.state.displayName,
            codexState: observedCodexState,
            codexDetail: observedCodexDetail,
            codexMicAvailable: codexMicAvailable,
            accessibilityAvailable: accessibilityAvailable
        )
    }

    private var runtimeBLEDescription: String {
        switch bleState {
        case .unavailable: "蓝牙不可用"
        case .scanning: "正在扫描"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .disconnected: "未连接"
        case .failed(let reason): "失败：\(reason)"
        }
    }

    private var runtimeWiFiDescription: String {
        let fallback = CompanionLANEndpoint.preferredIPv4Address().map {
            "；备用 \($0):\(WiFiControlServer.defaultPort)"
        } ?? ""
        return switch wifiState {
        case .stopped: "未启动"
        case .listening(let port): "等待设备（端口 \(port)\(fallback)）"
        case .connected: "已连接"
        case .failed(let reason): "失败：\(reason)\(fallback)"
        }
    }

    private func schedule(
        every interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            Task { @MainActor in action() }
        }
        timer.resume()
        timers.append(timer)
    }

    private func drainHooks() {
        guard let payloads = try? hookInbox.drain() else { return }
        for payload in payloads {
            guard let event = CodexHookEventParser.parse(payload) else { continue }
            let snapshot = controlReducer.reduce(hook: event)
            if snapshot.state == .approvalRequired {
                sendState(snapshot.state)
                pendingApprovalUntil = Date().addingTimeInterval(1.5)
            } else {
                closePrompt()
                sendState(snapshot.state)
            }
        }
    }

    private func pollCodexRollout() {
        guard let snapshot = rolloutMonitor.poll() else { return }
        observedCodexState = snapshot.state
        observedCodexDetail = snapshot.detail
        let reduced = controlReducer.reduce(hook: CodexHookEvent(state: snapshot.state))
        if reduced.state != .approvalRequired {
            closePrompt()
        }
        sendState(reduced.state)
    }

    private func pollApprovalDialog() {
        // Device approvals expire independently from the Mac UI. Never let a
        // stale device button retain authority after the reducer's 30-second
        // capability window has elapsed.
        if activePrompt != nil, controlReducer.currentSnapshot() == nil {
            closePrompt()
            return
        }
        guard activePrompt == nil, let deadline = pendingApprovalUntil else { return }
        if Date() > deadline {
            pendingApprovalUntil = nil
            return
        }
        guard let options = try? approvals.options(), !options.isEmpty else { return }
        nextPromptID &+= 1
        let prompt = DevicePromptPayload(id: nextPromptID, options: options)
        guard let payload = try? DevicePromptPayloadCodec.encode(prompt) else {
            pendingApprovalUntil = nil
            return
        }
        activePrompt = prompt
        activePromptRevision = controlReducer.currentSnapshot()?.revision
        pendingApprovalUntil = nil
        send(type: .promptOpen, payload: payload)
    }

    private func refreshQuota(force: Bool) {
        guard !quotaRefreshInFlight else { return }
        quotaRefreshInFlight = true
        let client = quotaClient
        Task { [weak self] in
            let snapshot = await Task.detached {
                try? client.readQuota(timeout: 5)
            }.value
            guard let self else { return }
            self.quotaRefreshInFlight = false
            guard let snapshot else { return }
            self.applyQuota(snapshot, force: force)
        }
    }

    private func applyQuota(_ snapshot: QuotaSnapshot, force: Bool) {
        let changed = snapshot.fiveHourRemainingPercent != latestQuota?.fiveHourRemainingPercent ||
            snapshot.weekRemainingPercent != latestQuota?.weekRemainingPercent
        latestQuota = snapshot
        guard force || changed else { return }
        let five = snapshot.fiveHourRemainingPercent.map { UInt8(max(0, min(100, $0)).rounded()) }
        let week = snapshot.weekRemainingPercent.map { UInt8(max(0, min(100, $0)).rounded()) }
        if let payload = try? DevicePayloadCodec.quota(fiveHour: five, week: week) {
            send(type: .quotaUpdate, payload: payload)
        }
    }

    private func handleControl(_ data: Data, key: Data, transport: ControlTransport) {
        guard let envelope = try? ControlEnvelopeCodec.decode(data, key: key) else { return }
        switch transport {
        case .ble:
            guard (try? bleInboundGuard.accept(envelope.sequence)) != nil else { return }
        case .wifi:
            guard (try? wifiInboundGuard.accept(envelope.sequence)) != nil else { return }
        }
        peerLiveness.markAuthenticatedInput(at: ProcessInfo.processInfo.systemUptime)
        switch envelope.messageType {
        case .pttDown:
            FileHandle.standardError.write(Data("[Codex Voice] PTT_DOWN received\n".utf8))
            if transport == .ble { ble.resetAudioSession() }
            beginVoiceSession()
        case .pttUp:
            FileHandle.standardError.write(Data("[Codex Voice] PTT_UP received\n".utf8))
            endVoiceSession()
        case .optionSelect: handleSelection(envelope.payload, confirmedLongPress: false)
        case .longPressConfirm: handleSelection(envelope.payload, confirmedLongPress: true)
        case .heartbeat: send(type: .ack, payload: Data([0xA0]))
        default: break
        }
    }

    private func handleSelection(_ payload: Data, confirmedLongPress: Bool) {
        guard let selection = try? DevicePromptPayloadCodec.decodeSelection(payload),
              let prompt = activePrompt,
              let promptRevision = activePromptRevision,
              controlReducer.applyRemoteAcknowledgement(revision: promptRevision) != nil,
              prompt.id == selection.promptID,
              prompt.options.indices.contains(Int(selection.optionIndex)) else { return }
        let option = prompt.options[Int(selection.optionIndex)]
        do {
            try approvals.press(option: option, confirmedLongPress: confirmedLongPress)
            closePrompt()
            sendState(.working)
        } catch CodexApprovalError.confirmationRequired {
            sendState(.confirmationRequired)
        } catch {
            // The live dialog changed or could not be identified. Keep the Mac
            // prompt untouched and close only the stale device projection.
            closePrompt()
        }
    }

    private func closePrompt() {
        guard activePrompt != nil else { return }
        activePrompt = nil
        activePromptRevision = nil
        pendingApprovalUntil = nil
        send(type: .promptClose, payload: Data([0xA0]))
    }

    private func beginVoiceSession(usingNativeUSBMic: Bool = false) {
        guard accessibility.canStartVoiceInput() else {
            lastVoiceError = "Codex 输入框不可用"
            failVoiceSession()
            return
        }
        let profiles = (try? profileStore.load()) ?? []
        let current = inputSources.currentInputSourceID()
        let selectedProfile = VoiceProfileResolver().resolve(
            profiles: profiles,
            activeInputSourceID: current
        )
        // Keep BOOT → Fn available on a fresh install, but once the user has
        // created profiles the GUI owns the mapping completely (including the
        // ability to disable every profile safely).
        guard let profile = selectedProfile ?? (profiles.isEmpty ? .bootFnDefault : nil) else {
            lastVoiceError = "当前输入法没有启用的语音快捷键配置"
            failVoiceSession()
            return
        }
        savedInputSourceID = current
        shouldRestoreInputSource = profile.restoreInputSource
        do {
            if profile.matchPolicy == .always,
               let target = profile.inputSourceIDs.first,
               target != current {
                try inputSources.select(id: target)
            }
            try ptt.buttonDown(profile: profile)
            // Fn is emitted by PTTController before this call. BLE audio uses
            // the optional CoreAudio socket. USB uses the physical UAC device
            // directly, which avoids virtual-driver rejection by input methods.
            if !usingNativeUSBMic { try sink.beginSession() }
            activeProfile = profile
            activeVoiceProfileName = profile.displayName
            lastVoiceError = nil
            FileHandle.standardError.write(
                Data("[Codex Voice] session started with \(profile.displayName)\n".utf8)
            )
            sendState(.listening)
        } catch {
            lastVoiceError = String(describing: error)
            FileHandle.standardError.write(
                Data("[Codex Voice] start failed: \(String(describing: error))\n".utf8)
            )
            failVoiceSession()
        }
    }

    private func endVoiceSession() {
        guard let profile = activeProfile else {
            failVoiceSession()
            return
        }
        do {
            try ptt.buttonUp(deferRouteRestore: true)
            activeProfile = nil
            sendState(.working)
            let delay = TimeInterval(profile.postRollMs + profile.commitGraceMs) / 1000
            let work = DispatchWorkItem { [weak self] in
                self?.ptt.finishDeferredRestore()
                self?.restoreInputSource()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } catch {
            lastVoiceError = String(describing: error)
            FileHandle.standardError.write(
                Data("[Codex Voice] stop failed: \(String(describing: error))\n".utf8)
            )
            failVoiceSession()
        }
    }

    private func failVoiceSession() {
        ptt.cancel()
        activeProfile = nil
        activeVoiceProfileName = nil
        restoreInputSource()
        sendState(.voiceError)
    }

    private func restoreInputSource() {
        defer {
            savedInputSourceID = nil
            shouldRestoreInputSource = false
        }
        guard shouldRestoreInputSource,
              let savedInputSourceID else { return }
        try? inputSources.select(id: savedInputSourceID)
    }

    private func sendState(_ state: DeviceState) {
        usbControl.send(state: state)
        usbControlState = usbControl.state
        guard let payload = try? DevicePayloadCodec.state(state) else { return }
        send(type: .stateUpdate, payload: payload)
    }

    private func send(type: ControlMessageType, payload: Data) {
        guard let key = pairingSecret ?? ble.sharedKey else { return }
        outboundSequence &+= 1
        let envelope = ControlEnvelope(
            version: 1,
            sequence: outboundSequence,
            messageType: type,
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload
        )
        guard let encoded = try? ControlEnvelopeCodec.encode(envelope, key: key) else { return }
        if case .connected = ble.state { try? ble.sendControl(encoded) }
        wifiServer?.sendControl(encoded)
    }

    private func startWiFiControl() {
        do {
            let secret = try keyManager.loadOrCreate()
            pairingSecret = secret
            let identity = wifiHostIdentity(secret: secret)
            let server = try WiFiControlServer(
                pairingSecret: secret,
                hostIdentity: identity
            )
            server.onControlMessage = { [weak self] data in
                Task { @MainActor in self?.handleControl(data, key: secret, transport: .wifi) }
            }
            server.onStateChange = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.wifiState = state
                    switch state {
                    case .connected:
                        self.wifiInboundGuard.reset()
                        self.peerLiveness.markAuthenticatedInput(
                            at: ProcessInfo.processInfo.systemUptime
                        )
                        self.refreshQuota(force: true)
                        self.sendState(self.controlReducer.currentSnapshot()?.state ?? .idle)
                    case .failed(let message):
                        self.lastVoiceError = "Wi-Fi 控制连接失败：\(message)"
                    default:
                        break
                    }
                }
            }
            wifiServer = server
            server.start()
        } catch {
            // BLE stays usable if a Keychain or Network failure prevents Wi-Fi
            // from starting. The dashboard exposes this as a recoverable error.
            lastVoiceError = "Wi-Fi 控制服务无法启动：\(error)"
        }
    }

    private func wifiHostIdentity(secret: Data) -> CompanionHostIdentity {
        var material = Data("codex-wifi-host-identity-v2".utf8)
        material.append(secret)
        let fingerprint = Data(SHA256.hash(data: material)).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return CompanionHostIdentity(
            id: "host-\(fingerprint.prefix(8))",
            publicKeyFingerprint: fingerprint
        )
    }
}
#endif
