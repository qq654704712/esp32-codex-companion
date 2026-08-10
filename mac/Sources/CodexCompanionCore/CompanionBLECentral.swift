#if os(macOS)
@preconcurrency import CoreBluetooth
import Foundation

public struct CompanionBLEDeviceCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

struct BLEConnectionReadiness: Equatable, Sendable {
    var controlNotifications = false
    var audioNotifications = false
    var provisioned = false

    var isReady: Bool {
        controlNotifications && audioNotifications && provisioned
    }

    mutating func reset() {
        self = BLEConnectionReadiness()
    }
}

@MainActor
public final class CompanionBLECentral: NSObject {
    public static let selectionDidChangeNotification = Notification.Name(
        "com.codexcompanion.selectedBLEDeviceDidChange"
    )
    public static let serviceUUID = CBUUID(string: "4F50454E-4149-434F-4445-584D49430001")
    public static let controlUUID = CBUUID(string: "4F50454E-4149-434F-4445-584D49430002")
    public static let audioUUID = CBUUID(string: "4F50454E-4149-434F-4445-584D49430003")
    public static let provisionUUID = CBUUID(string: "4F50454E-4149-434F-4445-584D49430004")
    private static let deviceName = "Codex Companion"
    private static let shortAdvertisedName = "Codex"

    public enum State: Equatable, Sendable {
        case unavailable
        case scanning
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    public var onStateChange: ((State) -> Void)?
    public var onControlMessage: ((Data) -> Void)?
    public var onAudioError: ((Error) -> Void)?
    public var onCandidatesChange: (([CompanionBLEDeviceCandidate]) -> Void)?
    public var onSelectedDeviceChange: ((UUID?) -> Void)?
    /// Any authenticated notification proves that the BLE transport is alive.
    /// Audio must count here too: a long press-to-talk stream can legitimately
    /// carry audio continuously while a control ACK is delayed behind it.
    public var onInboundActivity: (() -> Void)?

    public private(set) var state: State = .disconnected {
        didSet {
            // The companion normally runs headless, so connection transitions
            // must be visible in its standard output. This is deliberately
            // concise: it distinguishes a macOS Bluetooth permission/state
            // problem from discovery, pairing, or GATT provisioning failures.
            print("[Codex BLE] state = \(String(describing: state))")
            onStateChange?(state)
        }
    }

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var peripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var provisionCharacteristic: CBCharacteristic?
    private let audioPipeline: AudioFramePipeline
    public private(set) var sharedKey: Data?
    private let keyManager: ApplicationKeyManager
    private let identityStore = HostProvisioningIdentityStore()
    private let selectionDefaults = UserDefaults.standard
    private let selectedDeviceDefaultsKey = "companion.selected-ble-device.v1"
    private var candidates: [UUID: CompanionBLEDeviceCandidate] = [:]
    private var candidatePeripherals: [UUID: CBPeripheral] = [:]
    private var userSelectionScan = false
    public private(set) var selectedDeviceID: UUID?
    private var keyLoadInFlight = false
    private enum ScanMode: String {
        case serviceFiltered = "服务扫描"
        case broad = "全量扫描"
    }
    private var scanMode: ScanMode = .serviceFiltered
    private var scanGeneration = 0
    private var outboundControlFrameID: UInt16 = 0
    private var controlReassembler = BLEControlReassembler()
    private var readiness = BLEConnectionReadiness()
    private var provisioningRetryCount = 0
    private let maximumProvisioningRetries = 5

    private func trace(_ message: String) {
        FileHandle.standardError.write(Data("[Codex BLE] \(message)\n".utf8))
    }

    public init(
        audioSink: FloatAudioSink,
        keyManager: ApplicationKeyManager = ApplicationKeyManager()
    ) {
        audioPipeline = AudioFramePipeline(sink: audioSink)
        self.keyManager = keyManager
        if let value = UserDefaults.standard.string(
            forKey: "companion.selected-ble-device.v1"
        ) {
            selectedDeviceID = UUID(uuidString: value)
        }
        super.init()
    }

    public func start() {
        guard sharedKey != nil else {
            loadSharedKeyThenStart()
            return
        }
        _ = central
        trace("central state on start = \(String(describing: central.state))")
        if central.state == .poweredOn { scan() }
    }

    /// Keychain access can wait on keychain services or show a system prompt.
    /// It must never run while SwiftUI is constructing the first window.
    private func loadSharedKeyThenStart() {
        guard !keyLoadInFlight else { return }
        keyLoadInFlight = true
        let keyManager = keyManager
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = try? keyManager.loadOrCreate()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.keyLoadInFlight = false
                guard let key else {
                    self.state = .failed("无法读取蓝牙安全密钥")
                    return
                }
                self.sharedKey = key
                self.start()
            }
        }
    }

    public func stop() {
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        state = .disconnected
    }

    public func reconnect() {
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            scan()
        }
    }

    public func discoverDevices() {
        userSelectionScan = true
        candidates.removeAll()
        candidatePeripherals.removeAll()
        onCandidatesChange?([])
        _ = central
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    public func selectDevice(id: UUID) {
        guard let target = candidatePeripherals[id] else { return }
        userSelectionScan = false
        selectedDeviceID = id
        Self.persistSelectedDeviceID(id)
        onSelectedDeviceChange?(id)
        central.stopScan()
        if peripheral?.identifier == id, state == .connected { return }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        self.peripheral = target
        target.delegate = self
        state = .connecting
        central.connect(target)
    }

    public func forgetSelectedDevice() {
        selectedDeviceID = nil
        Self.persistSelectedDeviceID(nil)
        onSelectedDeviceChange?(nil)
        discoverDevices()
    }

    public static func persistSelectedDeviceID(_ id: UUID?) {
        let defaults = UserDefaults.standard
        let key = "companion.selected-ble-device.v1"
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
        DistributedNotificationCenter.default().post(
            name: selectionDidChangeNotification,
            object: nil
        )
    }

    public func reloadSelectedDeviceAndReconnect() {
        let value = selectionDefaults.string(forKey: selectedDeviceDefaultsKey)
        let updated = value.flatMap(UUID.init(uuidString:))
        guard updated != selectedDeviceID else { return }
        selectedDeviceID = updated
        onSelectedDeviceChange?(updated)
        userSelectionScan = false
        reconnect()
    }

    /// Opens a new authenticated PTT audio session. The firmware sends the
    /// matching control notification before it starts audio notifications.
    public func resetAudioSession() {
        audioPipeline.resetSession()
    }

    public func sendControl(_ data: Data) throws {
        guard let peripheral, let controlCharacteristic else {
            throw BLECentralError.notConnected
        }
        outboundControlFrameID &+= 1
        for fragment in try BLEControlFramer.fragment(data, frameID: outboundControlFrameID) {
            peripheral.writeValue(fragment, for: controlCharacteristic, type: .withResponse)
        }
    }

    private func scan() {
        guard central.state == .poweredOn else {
            trace("scan skipped: central state is \(String(describing: central.state))")
            return
        }
        central.stopScan()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanMode = .serviceFiltered
        state = .scanning
        // Prefer a service-filtered scan. It is both lower-noise and gives
        // CoreBluetooth the exact 128-bit UUID it needs on controllers that
        // suppress broad advertisements. If the controller produces no
        // callback, automatically retry broadly after a short grace period.
        trace("\(scanMode.rawValue) authorization=\(String(describing: CBManager.authorization))")
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        // CoreBluetooth's daemon is allowed to run with no visible GUI window,
        // so use a detached clock rather than a run-loop Timer. It hops back to
        // the central's actor before inspecting any CoreBluetooth state.
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.beginBroadScanIfNeeded(generation: generation)
        }
    }

    private func beginBroadScanIfNeeded(generation: Int) {
        trace("服务扫描窗口结束")
        guard scanGeneration == generation,
              peripheral == nil,
              central.state == .poweredOn else { return }
        central.stopScan()
        scanMode = .broad
        trace("服务扫描未发现设备；切换至全量扫描")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func completeConnectionIfReady() {
        if readiness.isReady { state = .connected }
    }

    private func writeProvisioningKey(
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        guard let sharedKey else {
            state = .failed("application key unavailable")
            return
        }
        let profile = HostProvisioningProfile(
            hostID: identityStore.loadOrCreateID(),
            displayName: identityStore.safeDisplayName(),
            capabilities: .macCompanion,
            pairingSecret: sharedKey
        )
        guard let packet = try? profile.encode() else {
            state = .failed("无法生成主机配对资料")
            return
        }
        peripheral.writeValue(packet, for: characteristic, type: .withResponse)
    }

    private func isTransientSecurityError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == CBATTErrorDomain else { return false }
        return error.code == CBATTError.insufficientEncryption.rawValue ||
               error.code == CBATTError.insufficientAuthentication.rawValue
    }

    private func retryProvisioningAfterSecurityHandshake(
        peripheral expectedPeripheral: CBPeripheral,
        characteristic expectedCharacteristic: CBCharacteristic
    ) {
        guard provisioningRetryCount < maximumProvisioningRetries else {
            state = .failed("蓝牙加密握手超时")
            central.cancelPeripheralConnection(expectedPeripheral)
            return
        }
        provisioningRetryCount += 1
        let attempt = provisioningRetryCount
        state = .connecting
        trace("等待蓝牙加密后重试配对（\(attempt)/\(maximumProvisioningRetries)）")
        Task { @MainActor [weak self, weak expectedPeripheral] in
            try? await Task.sleep(for: .seconds(1))
            guard let self,
                  let expectedPeripheral,
                  self.peripheral === expectedPeripheral,
                  self.provisionCharacteristic === expectedCharacteristic,
                  !self.readiness.provisioned else { return }
            self.writeProvisioningKey(
                to: expectedPeripheral,
                characteristic: expectedCharacteristic
            )
        }
    }

    private func resumeScanningAfterConnectionFailure() {
        // A device firmware refresh can invalidate its bonded-peer database.
        // Drop the stale CBPeripheral object before the next scan so that, once
        // the user removes the old macOS pairing, CoreBluetooth can negotiate
        // a fresh encrypted connection without restarting this daemon.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.state != .connected else { return }
            self.peripheral = nil
            if !self.userSelectionScan { self.scan() }
        }
    }
}

public enum BLECentralError: Error, Equatable {
    case notConnected
    case requiredCharacteristicMissing
}

extension CompanionBLECentral: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            trace("central state changed to \(String(describing: central.state))")
            if central.state == .poweredOn {
                scan()
            } else {
                state = .unavailable
            }
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let discoveredName = advertisedName ?? peripheral.name ?? "unnamed"
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        // This delegate is explicitly nonisolated; construct the immutable
        // UUID locally instead of touching an @MainActor static property.
        let companionServiceUUID = CBUUID(string: "4F50454E-4149-434F-4445-584D49430001")
        let advertisesCompanionService = advertisedServices.contains(companionServiceUUID)
        let rssi = RSSI.intValue
        FileHandle.standardError.write(
            Data("[Codex BLE] advertisement name=\(discoveredName) services=\(advertisedServices.map(\.uuidString).joined(separator: ",")) rssi=\(rssi)\n".utf8)
        )
        Task { @MainActor in
            // Never connect to arbitrary nearby BLE devices.  A matching name
            // merely permits GATT discovery;
            // encrypted provisioning and the persisted HMAC key remain the
            // trust boundary. The short primary name handles controllers which
            // omit service UUIDs or delay a scan response; the connection is
            // still rejected immediately if GATT does not expose our service.
            let isCompanion = (advertisedName == Self.deviceName ||
                               peripheral.name == Self.deviceName) ||
                              advertisedName == Self.shortAdvertisedName ||
                              (advertisesCompanionService &&
                               discoveredName.contains("Codex"))
            guard isCompanion else { return }
            let candidate = CompanionBLEDeviceCandidate(
                id: peripheral.identifier,
                name: discoveredName,
                rssi: rssi
            )
            self.candidates[peripheral.identifier] = candidate
            self.candidatePeripherals[peripheral.identifier] = peripheral
            self.onCandidatesChange?(self.candidates.values.sorted {
                if $0.rssi == $1.rssi { return $0.name < $1.name }
                return $0.rssi > $1.rssi
            })
            guard !self.userSelectionScan, self.peripheral == nil else { return }
            if let selectedDeviceID = self.selectedDeviceID,
               selectedDeviceID != peripheral.identifier { return }
            if self.selectedDeviceID == nil {
                // Migrate the old auto-connect behavior once, then make future
                // device changes an explicit dashboard action.
                self.selectedDeviceID = peripheral.identifier
                Self.persistSelectedDeviceID(peripheral.identifier)
                self.onSelectedDeviceChange?(peripheral.identifier)
            }
            print("[Codex BLE] discovered \(discoveredName), RSSI \(rssi)")
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            print("[Codex BLE] connected; discovering service")
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.peripheral?.identifier == peripheral.identifier else { return }
            print("[Codex BLE] connection failed: \(error?.localizedDescription ?? "unknown")")
            state = .failed(error?.localizedDescription ?? "connection failed")
            resumeScanningAfterConnectionFailure()
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.peripheral?.identifier == peripheral.identifier else { return }
            print("[Codex BLE] disconnected: \(error?.localizedDescription ?? "clean disconnect")")
            controlCharacteristic = nil
            audioCharacteristic = nil
            provisionCharacteristic = nil
            provisioningRetryCount = 0
            readiness.reset()
            state = error == nil ? .disconnected : .failed(error!.localizedDescription)
            self.peripheral = nil
            if !self.userSelectionScan { scan() }
        }
    }
}

extension CompanionBLECentral: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                print("[Codex BLE] service discovery failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                print("[Codex BLE] required service missing")
                state = .failed("service missing")
                return
            }
            print("[Codex BLE] service found; discovering characteristics")
            peripheral.discoverCharacteristics(
                [Self.controlUUID, Self.audioUUID, Self.provisionUUID],
                for: service
            )
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                print("[Codex BLE] characteristic discovery failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
                return
            }
            readiness.reset()
            provisioningRetryCount = 0
            controlCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.controlUUID })
            audioCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.audioUUID })
            provisionCharacteristic = service.characteristics?.first(where: { $0.uuid == Self.provisionUUID })
            guard let controlCharacteristic, let audioCharacteristic,
                  let provisionCharacteristic else {
                print("[Codex BLE] required characteristic missing")
                state = .failed("required characteristic missing")
                return
            }
            print("[Codex BLE] characteristics ready; enabling notifications and provisioning")
            peripheral.setNotifyValue(true, for: controlCharacteristic)
            peripheral.setNotifyValue(true, for: audioCharacteristic)
            // An encrypted write asks macOS to pair. A provisioned device
            // rejects replacement, while a factory-new device stores it.
            writeProvisioningKey(to: peripheral, characteristic: provisionCharacteristic)
            state = .connecting
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                print("[Codex BLE] notification setup failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
                return
            }
            print("[Codex BLE] notifications \(characteristic.uuid.uuidString) = \(characteristic.isNotifying)")
            if characteristic.uuid == Self.controlUUID {
                readiness.controlNotifications = characteristic.isNotifying
            } else if characteristic.uuid == Self.audioUUID {
                readiness.audioNotifications = characteristic.isNotifying
            }
            completeConnectionIfReady()
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard characteristic.uuid == Self.provisionUUID else { return }
            if let error {
                print("[Codex BLE] provisioning failed: \(error.localizedDescription)")
                if isTransientSecurityError(error) {
                    retryProvisioningAfterSecurityHandshake(
                        peripheral: peripheral,
                        characteristic: characteristic
                    )
                    return
                }
                state = .failed(error.localizedDescription)
                return
            }
            print("[Codex BLE] provisioning acknowledged")
            provisioningRetryCount = 0
            readiness.provisioned = true
            completeConnectionIfReady()
        }
    }

    nonisolated public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                onAudioError?(error)
                return
            }
            guard let value = characteristic.value else { return }
            onInboundActivity?()
            if characteristic.uuid == Self.audioUUID {
                do { try audioPipeline.ingest(value) } catch { onAudioError?(error) }
            } else if characteristic.uuid == Self.controlUUID {
                do {
                    if let packet = try controlReassembler.accept(value) {
                        onControlMessage?(packet)
                    }
                } catch {
                    onAudioError?(error)
                }
            }
        }
    }
}
#endif
