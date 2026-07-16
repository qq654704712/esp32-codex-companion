#if os(macOS)
import CoreAudio
import Foundation

public protocol CoreAudioRoutingAPI: AnyObject {
    func defaultInputDevice() throws -> UInt32
    func deviceID(uid: String) throws -> UInt32?
    func deviceID(named: String) throws -> UInt32?
    func setDefaultInputDevice(_ id: UInt32) throws
}

public enum AudioRouteError: Error, Equatable {
    case codexMicNotFound
    case confirmationTimedOut
    case coreAudio(OSStatus)
}

public final class CodexMicRouteManager: AudioRouteManaging {
    public static let deviceUID = "com.codexcompanion.mic.device"
    /// The native ESP32-S3 UAC descriptor name. Prefer it over the optional
    /// HAL driver because applications such as Doubao can reject virtual
    /// audio drivers while accepting a hardware USB microphone.
    public static let usbMicrophoneName = "Codex Companion USB Mic"

    private let api: CoreAudioRoutingAPI
    private let confirmationAttempts: Int
    private var previousDevice: UInt32?

    public init(
        api: CoreAudioRoutingAPI = SystemCoreAudioRoutingAPI(),
        confirmationAttempts: Int = 50
    ) {
        self.api = api
        self.confirmationAttempts = max(1, confirmationAttempts)
    }

    public func prepareCodexMic() throws {
        guard let codexMic = try preferredInputDevice() else {
            throw AudioRouteError.codexMicNotFound
        }
        let previous = try api.defaultInputDevice()
        previousDevice = previous
        if previous != codexMic { try api.setDefaultInputDevice(codexMic) }
        for _ in 0..<confirmationAttempts {
            if try api.defaultInputDevice() == codexMic { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AudioRouteError.confirmationTimedOut
    }

    public func restorePreviousRoute() {
        defer { previousDevice = nil }
        guard let previousDevice else { return }
        try? api.setDefaultInputDevice(previousDevice)
    }

    public func preferredInputDevice() throws -> UInt32? {
        if let usbMic = try api.deviceID(named: Self.usbMicrophoneName) {
            return usbMic
        }
        return try api.deviceID(uid: Self.deviceUID)
    }
}

public final class SystemCoreAudioRoutingAPI: CoreAudioRoutingAPI {
    public init() {}

    public func defaultInputDevice() throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr else { throw AudioRouteError.coreAudio(status) }
        return device
    }

    public func deviceID(uid targetUID: String) throws -> UInt32? {
        for device in try devices() {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidReference: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(
                device, &uidAddress, 0, nil, &uidSize, &uidReference
            )
            if status == noErr, let uidReference,
               uidReference.takeRetainedValue() as String == targetUID {
                return device
            }
        }
        return nil
    }

    public func deviceID(named targetName: String) throws -> UInt32? {
        for device in try devices() {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameReference: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(
                device, &nameAddress, 0, nil, &nameSize, &nameReference
            )
            if status == noErr, let nameReference,
               nameReference.takeRetainedValue() as String == targetName {
                return device
            }
        }
        return nil
    }

    private func devices() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr else { throw AudioRouteError.coreAudio(status) }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        )
        guard status == noErr else { throw AudioRouteError.coreAudio(status) }
        return devices
    }

    public func setDefaultInputDevice(_ id: UInt32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(id)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout.size(ofValue: device)),
            &device
        )
        guard status == noErr else { throw AudioRouteError.coreAudio(status) }
    }
}
#endif
