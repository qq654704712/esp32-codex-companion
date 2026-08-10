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

enum VoiceSessionSource: Equatable, Sendable {
    case usb
    case ble
    case wifi

    var requiresPeerLiveness: Bool { self != .usb }

    func isAffected(byLossOf source: VoiceSessionSource) -> Bool {
        self == source
    }
}

@MainActor
public final class CompanionService: ObservableObject {
    @Published public private(set) var bleState: CompanionBLECentral.State = .disconnected
    @Published public private(set) var discoveredBLEDevices: [CompanionBLEDeviceCandidate] = []
    @Published public private(set) var selectedBLEDeviceID: UUID?
    @Published public private(set) var codexMicAvailable = false
    @Published public private(set) var accessibilityAvailable = false
    @Published public private(set) var codexComposerAvailable = false
    /// The companion window cannot inspect the Codex editor while it is frontmost.
    /// Keep the latest check made while Codex itself owned the foreground instead
    /// of replacing it with a false result as soon as the user opens this window.
    @Published public private(set) var codexComposerCheckedAt: Date?
    @Published public private(set) var observedCodexState: DeviceState = .idle
    @Published public private(set) var observedCodexDetail = "等待 Codex 会话"
    @Published public private(set) var observedActiveTasks: UInt8 = 0
    @Published public private(set) var observedAttentionTasks: UInt8 = 0
    @Published public private(set) var usbControlState: USBControlState = .stopped
    @Published public private(set) var activeVoiceProfileName: String?
    @Published public private(set) var lastVoiceError: String?
    @Published public private(set) var weatherStatus = "尚未配置城市"
    @Published public private(set) var isRunning = false
    private let sink: CodexMicSocketClient
    private let wifiAudioGateway: WiFiAudioGateway
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
    private let weatherStore: WeatherConfigurationStore
    private let weatherClient: OpenMeteoWeatherClient
    private let keyManager = ApplicationKeyManager()
    private var timers: [DispatchSourceTimer] = []
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var bleInboundGuard = SequenceGuard()
    private var wifiInboundGuard = SequenceGuard()
    private var mirroredControlDeduplicator = MirroredControlDeduplicator()
    private var peerLiveness = PeerLiveness(timeout: 6)
    private var outboundSequence: UInt32 = 0
    private var savedInputSourceID: String?
    private var shouldRestoreInputSource = false
    private var activeProfile: VoiceShortcutProfile?
    private var latestQuota: QuotaSnapshot?
    private var latestActivity = DeviceActivityPayload(
        state: .idle,
        activeTasks: 0,
        attentionTasks: 0,
        recentCompletedTasks: 0
    )
    private var quotaRefreshInFlight = false
    private var weatherRefreshInFlight = false
    private var latestWeather: WeatherSnapshot?
    private var loadedWeatherConfiguration = WeatherConfiguration()
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
    private var nativeUSBButtonEdges = USBButtonEdgeDeduplicator()
    private var activeVoiceSource: VoiceSessionSource?
    private var deferredVoiceCleanupGeneration: UInt64 = 0

    private enum ControlTransport: Equatable { case ble, wifi }

    public init(
        profileStore: VoiceProfileStore = VoiceProfileStore(),
        weatherStore: WeatherConfigurationStore = WeatherConfigurationStore(),
        weatherClient: OpenMeteoWeatherClient = OpenMeteoWeatherClient()
    ) {
        let sink = CodexMicSocketClient()
        self.sink = sink
        wifiAudioGateway = WiFiAudioGateway(sink: sink)
        ble = CompanionBLECentral(audioSink: sink)
        self.profileStore = profileStore
        self.weatherStore = weatherStore
        self.weatherClient = weatherClient
        ptt = PTTController(
            audio: RemoteAudioSession(),
            route: CodexMicRouteManager(),
            keys: CGEventShortcutEmitter()
        )
        selectedBLEDeviceID = ble.selectedDeviceID
        ble.onCandidatesChange = { [weak self] devices in
            self?.discoveredBLEDevices = devices
        }
        ble.onSelectedDeviceChange = { [weak self] id in
            self?.selectedBLEDeviceID = id
        }
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
            self?.handleNativeUSBButton(isDown)
        }
        usbControl.onSubmit = { [weak self] in
            self?.submitVoiceText()
        }
        usbControl.onPromptSelection = { [weak self] selection, confirmed in
            self?.handleSelection(selection, confirmedLongPress: confirmed)
        }
        usbControl.onWeatherConfiguration = { [weak self] payload in
            self?.applyWeatherConfigurationFromDevice(payload)
        }
        usbHIDPTT.onButton = { [weak self] isDown in
            self?.handleNativeUSBButton(isDown)
        }
        usbHIDPTT.start()
        usbControl.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.usbControlState = self.usbControl.state
            if connected {
                self.sendState(self.controlReducer.currentSnapshot()?.state ?? self.observedCodexState)
                self.sendWeatherConfiguration()
                if let weather = self.latestWeather { self.sendWeather(weather) }
                self.refreshWeather(force: true)
            } else {
                // A cable removal can consume the release edge. Release any
                // active shortcut and restore the previous microphone route.
                self.handleNativeUSBButton(false)
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
                self.sendWeatherConfiguration()
                if let weather = self.latestWeather { self.sendWeather(weather) }
                self.refreshWeather(force: true)
            } else {
                self.peerLiveness.reset()
                if self.activeVoiceSource?.isAffected(byLossOf: .ble) == true {
                    // A lost link must never leave a synthesized modifier held
                    // or Codex Mic selected as the system default input. USB
                    // and Wi-Fi sessions do not depend on this BLE connection.
                    self.failVoiceSession(reason: "BLE connection lost")
                }
            }
        }
        ble.onControlMessage = { [weak self] data in
            guard let self, let key = self.ble.sharedKey else { return }
            self.handleControl(data, key: key, transport: .ble)
        }
        ble.onAudioError = { [weak self] error in
            guard let self,
                  self.activeVoiceSource?.isAffected(byLossOf: .ble) == true else { return }
            FileHandle.standardError.write(
                Data("[Codex Voice] audio write failed: \(String(describing: error))\n".utf8)
            )
            self.lastVoiceError = String(describing: error)
            self.failVoiceSession(reason: "BLE audio failed")
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
        // Rollout parsing is the hook-free fallback and scans a bounded journal
        // tail. One update per second keeps the device responsive without
        // making the always-on daemon repeatedly parse JSON while Codex works.
        // Installed hooks still arrive through the 50 ms inbox above.
        schedule(every: 1) { [weak self] in self?.pollCodexRollout() }
        schedule(every: 2) { [weak self] in
            guard let self else { return }
            let now = Int64(Date().timeIntervalSince1970)
            let fresh = self.latestQuota.map { now - $0.updatedAt <= 120 } ?? false
            self.send(type: .heartbeat, payload: DevicePayloadCodec.heartbeat(quotaFresh: fresh))
        }
        schedule(every: 1) { [weak self] in
            guard let self, (self.ble.state == .connected || self.wifiState == .connected),
                  self.peerLiveness.isExpired(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.peerLiveness.reset()
            if self.activeVoiceSource?.requiresPeerLiveness == true {
                self.failVoiceSession(reason: "wireless peer liveness expired")
            }
            self.ble.reconnect()
        }
        schedule(every: 60) { [weak self] in self?.refreshQuota(force: false) }
        schedule(every: 15) { [weak self] in self?.refreshWeather(force: false) }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota(force: true) }
        })
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: CompanionBLECentral.selectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.ble.reloadSelectedDeviceAndReconnect() }
        })
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: WeatherConfigurationStore.configurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadWeatherConfiguration() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHostStatus() }
        })
        refreshQuota(force: true)
        reloadWeatherConfiguration()
    }

    public func discoverCompanionDevices() {
        ble.discoverDevices()
    }

    public func selectCompanionDevice(id: UUID) {
        if isRunning {
            ble.selectDevice(id: id)
        } else {
            CompanionBLECentral.persistSelectedDeviceID(id)
            selectedBLEDeviceID = id
        }
    }

    public func forgetSelectedCompanionDevice() {
        if isRunning {
            ble.forgetSelectedDevice()
        } else {
            CompanionBLECentral.persistSelectedDeviceID(nil)
            selectedBLEDeviceID = nil
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        isRunning = false
        timers.forEach { $0.cancel() }
        timers.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        distributedObservers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
        }
        distributedObservers.removeAll()
        ptt.cancel()
        deferredVoiceCleanupGeneration &+= 1
        activeVoiceSource = nil
        usbHIDPTT.stop()
        nativeUSBButtonEdges.reset()
        restoreInputSource()
        usbControl.stop()
        usbControlState = .stopped
        ble.stop()
        wifiAudioGateway.cancelPTT()
        try? wifiAudioGateway.configure(session: nil)
        wifiAudioGateway.stop()
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

    public func reloadWeatherConfiguration() {
        loadedWeatherConfiguration = weatherStore.load()
        sendWeatherConfiguration()
        refreshWeather(force: true)
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
            let normalized = CodexHookEvent(
                state: event.state == .writing ? .working : event.state,
                sessionID: event.sessionID,
                turnID: event.turnID
            )
            let snapshot = controlReducer.reduce(hook: normalized)
            if isInteractiveState(snapshot.state) {
                sendState(snapshot.state)
                pendingApprovalUntil = Date().addingTimeInterval(30)
            } else {
                closePrompt()
                sendState(snapshot.state)
            }
        }
    }

    private func pollCodexRollout() {
        guard let snapshot = rolloutMonitor.poll() else { return }
        FileHandle.standardError.write(Data((
            "[Codex Tasks] state=\(snapshot.state.rawValue) active=\(snapshot.activeTasks) "
                + "attention=\(snapshot.attentionTasks) completed=\(snapshot.recentCompletedTasks) "
                + "events=\(snapshot.events.map { $0.kind == .started ? "start" : "done" }.joined(separator: ","))\n"
        ).utf8))
        observedCodexState = snapshot.state
        observedCodexDetail = snapshot.detail
        observedActiveTasks = snapshot.activeTasks
        observedAttentionTasks = snapshot.attentionTasks
        latestActivity = DeviceActivityPayload(
            state: snapshot.state,
            activeTasks: snapshot.activeTasks,
            attentionTasks: snapshot.attentionTasks,
            recentCompletedTasks: snapshot.recentCompletedTasks
        )
        let reduced = controlReducer.reduce(hook: CodexHookEvent(state: snapshot.state))
        if !isInteractiveState(reduced.state) {
            closePrompt()
        } else if activePrompt == nil {
            pendingApprovalUntil = Date().addingTimeInterval(30)
        }
        sendState(reduced.state)
        for event in snapshot.events {
            usbControl.send(taskEvent: event.kind)
            send(type: .taskEvent, payload: DevicePayloadCodec.taskEvent(event.kind))
        }
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
        usbControl.sendPrompt(payload)
        send(type: .promptOpen, payload: payload)
    }

    private func isInteractiveState(_ state: DeviceState) -> Bool {
        state == .approvalRequired || state == .inputRequired ||
            state == .confirmationRequired
    }

    private func refreshQuota(force: Bool) {
        guard !quotaRefreshInFlight else { return }
        quotaRefreshInFlight = true
        let client = quotaClient
        Task { [weak self] in
            let result = await Task.detached { () -> Result<QuotaSnapshot, Error> in
                Result { try client.readQuota(timeout: 5) }
            }.value
            guard let self else { return }
            self.quotaRefreshInFlight = false
            switch result {
            case .success(let snapshot):
                self.applyQuota(snapshot, force: force)
            case .failure(let error):
                FileHandle.standardError.write(Data(
                    "[Codex Quota] refresh failed: \(error)\n".utf8
                ))
            }
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

    private func refreshWeather(force: Bool) {
        let configuration = weatherStore.load()
        if configuration != loadedWeatherConfiguration {
            loadedWeatherConfiguration = configuration
            sendWeatherConfiguration()
        }
        guard configuration.enabled else {
            weatherStatus = "天气同步已关闭"
            return
        }
        guard !configuration.city.isEmpty else {
            weatherStatus = "请在 Companion 设置中填写城市"
            return
        }
        if !force, let latestWeather,
           Date().timeIntervalSince(latestWeather.fetchedAt) <
            TimeInterval(configuration.refreshMinutes) * 60 {
            return
        }
        guard !weatherRefreshInFlight else { return }
        weatherRefreshInFlight = true
        weatherStatus = "正在同步 \(configuration.city) 天气"
        let client = weatherClient
        Task { [weak self] in
            do {
                let snapshot = try await client.fetch(city: configuration.city)
                guard let self else { return }
                self.weatherRefreshInFlight = false
                self.latestWeather = snapshot
                self.weatherStatus = "\(snapshot.city) 已同步"
                self.sendWeather(snapshot)
            } catch {
                guard let self else { return }
                self.weatherRefreshInFlight = false
                self.weatherStatus = "天气同步失败：\(error.localizedDescription)"
                FileHandle.standardError.write(Data(
                    "[Codex Weather] refresh failed: \(error)\n".utf8
                ))
            }
        }
    }

    private func sendWeather(_ snapshot: WeatherSnapshot) {
        guard let payload = try? DevicePayloadCodec.weather(snapshot.devicePayload) else { return }
        usbControl.sendWeather(payload)
        send(type: .weatherUpdate, payload: payload)
    }

    private func sendWeatherConfiguration() {
        let config = loadedWeatherConfiguration
        let payload = DeviceWeatherConfigurationPayload(
            enabled: config.enabled,
            usesCelsius: config.usesCelsius,
            refreshMinutes: config.refreshMinutes
        )
        usbControl.sendWeatherConfiguration(payload)
        if let data = try? DevicePayloadCodec.weatherConfiguration(payload) {
            send(type: .weatherConfig, payload: data)
        }
    }

    private func applyWeatherConfigurationFromDevice(
        _ payload: DeviceWeatherConfigurationPayload
    ) {
        var configuration = weatherStore.load()
        configuration.enabled = payload.enabled
        configuration.usesCelsius = payload.usesCelsius
        configuration.refreshMinutes = payload.refreshMinutes
        do {
            try weatherStore.save(configuration)
            loadedWeatherConfiguration = configuration.normalized
            refreshWeather(force: true)
        } catch {
            weatherStatus = "天气设置保存失败：\(error.localizedDescription)"
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
        guard mirroredControlDeduplicator.accept(
            data,
            at: ProcessInfo.processInfo.systemUptime
        ) else { return }
        peerLiveness.markAuthenticatedInput(at: ProcessInfo.processInfo.systemUptime)
        switch envelope.messageType {
        case .pttDown:
            FileHandle.standardError.write(Data(
                "[Codex Voice] PTT_DOWN received transport=\(transport) sequence=\(envelope.sequence)\n".utf8
            ))
            let source: VoiceSessionSource
            if wifiAudioGateway.isSessionReady {
                source = .wifi
            } else {
                source = .ble
                ble.resetAudioSession()
            }
            beginVoiceSession(source: source)
        case .pttUp:
            FileHandle.standardError.write(Data(
                "[Codex Voice] PTT_UP received transport=\(transport) sequence=\(envelope.sequence)\n".utf8
            ))
            endVoiceSession()
        case .submit:
            FileHandle.standardError.write(Data(
                "[Codex Voice] SUBMIT received transport=\(transport) sequence=\(envelope.sequence)\n".utf8
            ))
            submitVoiceText()
        case .optionSelect: handleSelection(envelope.payload, confirmedLongPress: false)
        case .longPressConfirm: handleSelection(envelope.payload, confirmedLongPress: true)
        case .weatherConfig:
            if let payload = try? DevicePayloadCodec.decodeWeatherConfiguration(
                envelope.payload
            ) {
                applyWeatherConfigurationFromDevice(payload)
            }
        case .heartbeat: send(type: .ack, payload: Data([0xA0]))
        default: break
        }
    }

    private func handleNativeUSBButton(_ isDown: Bool) {
        guard let action = nativeUSBButtonEdges.action(
            for: isDown,
            at: ProcessInfo.processInfo.systemUptime
        ) else { return }
        if action == .down {
            beginVoiceSession(source: .usb)
        } else if activeProfile != nil {
            endVoiceSession()
        } else {
            // A failed start still needs the matching release to clear the
            // edge state, but it is not itself a second voice-session error.
            ptt.cancel()
        }
    }

    private func submitVoiceText() {
        guard activeProfile == nil else {
            lastVoiceError = "语音仍在录制，未发送"
            return
        }
        do {
            try ptt.submit()
            lastVoiceError = nil
            FileHandle.standardError.write(Data("[Codex Voice] Return emitted\n".utf8))
        } catch {
            lastVoiceError = "发送失败：\(error)"
            FileHandle.standardError.write(Data(
                "[Codex Voice] Return failed: \(String(describing: error))\n".utf8
            ))
        }
    }

    private func handleSelection(_ payload: Data, confirmedLongPress: Bool) {
        guard let selection = try? DevicePromptPayloadCodec.decodeSelection(payload) else { return }
        handleSelection(selection, confirmedLongPress: confirmedLongPress)
    }

    private func handleSelection(
        _ selection: DeviceOptionSelection, confirmedLongPress: Bool
    ) {
        guard let prompt = activePrompt,
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
        usbControl.closePrompt()
        send(type: .promptClose, payload: Data([0xA0]))
    }

    private func beginVoiceSession(source: VoiceSessionSource) {
        // A new physical press is authoritative. If the previous release is
        // still inside its input-method commit grace, finish that deferred
        // route/source cleanup now and invalidate its scheduled callback.
        // Without this, every quick second press fails as sessionAlreadyActive.
        deferredVoiceCleanupGeneration &+= 1
        if case .finishing = ptt.state {
            ptt.finishDeferredRestore()
            restoreInputSource()
        }
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
            try ptt.buttonDown(
                profile: profile,
                inputRoute: source == .usb ? .usbHardware : .codexMic
            )
            // Fn is emitted by PTTController before this call. BLE audio uses
            // the optional CoreAudio socket. USB uses the physical UAC device
            // directly, which avoids virtual-driver rejection by input methods.
            if source != .usb { try sink.beginSession() }
            activeProfile = profile
            activeVoiceSource = source
            activeVoiceProfileName = profile.displayName
            lastVoiceError = nil
            if source == .wifi {
                wifiAudioGateway.beginPTT()
            }
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
        let source = activeVoiceSource
        do {
            try ptt.buttonUp(deferRouteRestore: true)
            if source == .wifi {
                // Firmware capture owns a fixed 200 ms tail. Voice-profile
                // timing controls shortcut restoration, not UDP playout; using
                // a longer profile value here would synthesize silence and can
                // falsely trigger the 500 ms stall rule after release.
                wifiAudioGateway.endPTT(postRollMs: 200)
                logWiFiAudioDiagnostics()
            }
            activeProfile = nil
            activeVoiceSource = nil
            activeVoiceProfileName = nil
            sendState(.working)
            let delay = TimeInterval(profile.postRollMs + profile.commitGraceMs) / 1000
            deferredVoiceCleanupGeneration &+= 1
            let cleanupGeneration = deferredVoiceCleanupGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.deferredVoiceCleanupGeneration == cleanupGeneration else { return }
                self.ptt.finishDeferredRestore()
                self.restoreInputSource()
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

    private func failVoiceSession(reason: String? = nil) {
        if let reason {
            FileHandle.standardError.write(
                Data("[Codex Voice] session cancelled: \(reason)\n".utf8)
            )
        }
        deferredVoiceCleanupGeneration &+= 1
        if activeVoiceSource == .wifi { logWiFiAudioDiagnostics() }
        ptt.cancel()
        wifiAudioGateway.cancelPTT()
        activeProfile = nil
        activeVoiceSource = nil
        activeVoiceProfileName = nil
        restoreInputSource()
        sendState(.voiceError)
    }

    private func logWiFiAudioDiagnostics() {
        let snapshot = wifiAudioGateway.diagnosticsSnapshot()
        let latency = snapshot.firstOutputLatencyMs.map { String(format: "%.1f", $0) } ?? "none"
        let line = "[Codex Voice] Wi-Fi audio received=\(snapshot.received) "
            + "lost=\(snapshot.lost) late=\(snapshot.late) "
            + "replayed=\(snapshot.replayed) authFailures=\(snapshot.authenticationFailures) "
            + "sourceRejected=\(snapshot.sourceRejected) rebuffered=\(snapshot.rebuffered) "
            + "firstOutputMs=\(latency) maxJitterMs=\(String(format: "%.1f", snapshot.maximumJitterMs)) "
            + "longestGapMs=\(String(format: "%.1f", snapshot.longestGapMs)) "
            + "sourceFrameMs=\(String(format: "%.1f", snapshot.maximumSourceFrameIntervalMs)) "
            + "networkVariationMs=\(String(format: "%.1f", snapshot.maximumNetworkVariationMs))\n"
        FileHandle.standardError.write(Data(line.utf8))
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
        let activity = DeviceActivityPayload(
            state: state,
            activeTasks: latestActivity.activeTasks,
            attentionTasks: latestActivity.attentionTasks,
            recentCompletedTasks: latestActivity.recentCompletedTasks
        )
        guard let payload = try? DevicePayloadCodec.activity(activity) else { return }
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
            // The UDP receiver must be bound before the TCP service is
            // discoverable. Otherwise the device could select Wi-Fi audio for
            // an authenticated control session whose PCM destination is dead.
            try wifiAudioGateway.start()
            wifiAudioGateway.onFatalError = { [weak self] message in
                Task { @MainActor in
                    guard let self,
                          self.activeVoiceSource?.isAffected(byLossOf: .wifi) == true else { return }
                    self.lastVoiceError = message
                    self.failVoiceSession(reason: message)
                }
            }
            wifiAudioGateway.onAuthenticatedActivity = { [weak self] in
                Task { @MainActor in
                    self?.peerLiveness.markAuthenticatedInput(
                        at: ProcessInfo.processInfo.systemUptime
                    )
                }
            }
            wifiAudioGateway.onRecoverableStallChange = { stalled in
                let status = stalled ? "audio stalled; keeping physical PTT held"
                                     : "audio resumed during the same PTT"
                FileHandle.standardError.write(
                    Data("[Codex Voice] Wi-Fi \(status)\n".utf8)
                )
            }
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
            server.onAuthenticatedSessionChange = { [weak self] session in
                try? self?.wifiAudioGateway.configure(session: session)
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
                        self.sendWeatherConfiguration()
                        if let weather = self.latestWeather { self.sendWeather(weather) }
                        self.refreshWeather(force: true)
                    case .failed(let message):
                        self.lastVoiceError = "Wi-Fi 控制连接失败：\(message)"
                        if self.activeVoiceSource?.isAffected(byLossOf: .wifi) == true {
                            self.failVoiceSession(reason: "Wi-Fi control failed")
                        }
                    case .listening, .stopped:
                        if self.activeVoiceSource?.isAffected(byLossOf: .wifi) == true {
                            self.failVoiceSession(reason: "Wi-Fi connection lost")
                        }
                    }
                }
            }
            wifiServer = server
            server.start()
        } catch {
            // BLE stays usable if a Keychain or Network failure prevents Wi-Fi
            // from starting. The dashboard exposes this as a recoverable error.
            wifiAudioGateway.stop()
            lastVoiceError = "Wi-Fi 音频/控制服务无法启动：\(error)"
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
