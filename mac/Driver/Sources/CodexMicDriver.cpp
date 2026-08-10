#include "AudioRingBuffer.hpp"
#include "UnixAudioServer.hpp"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <os/log.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr AudioObjectID kPluginObject = kAudioObjectPlugInObject;
constexpr AudioObjectID kDeviceObject = 2;
constexpr AudioObjectID kStreamObject = 3;
constexpr Float64 kSampleRate = 48'000.0;
constexpr UInt32 kBufferFrames = 512;
constexpr std::size_t kRingCapacity = 48'000 * 4;
#if defined(CODEX_MIC_COMPAT_USB_TRANSPORT)
// Some microphone pickers enumerate Codex Mic through AVFoundation but then
// discard every CoreAudio device whose transport is `virtual`.  This opt-in
// compatibility build changes only the transport metadata; audio still comes
// from the authenticated local Companion socket and remains fully wireless.
// The product build enables this after physical validation with Doubao 0.9.4;
// a standards-oriented virtual transport build remains available explicitly.
constexpr UInt32 kReportedTransportType = kAudioDeviceTransportTypeUSB;
#else
constexpr UInt32 kReportedTransportType = kAudioDeviceTransportTypeVirtual;
#endif

std::atomic<ULONG> gRefCount{0};
std::atomic<UInt32> gRunningClients{0};
std::atomic<UInt32> gUnsupportedPropertyLogCount{0};
AudioServerPlugInHostRef gHost = nullptr;
AudioRingBuffer<kRingCapacity> gRing;
std::unique_ptr<UnixAudioServer<kRingCapacity>> gServer;
std::mutex gTimeMutex;
UInt64 gAnchorHostTime = 0;
UInt64 gTimestampNumber = 0;
double gHostTicksPerFrame = 0;

uid_t consoleUserID() {
    // HAL plug-ins are hosted by _coreaudiod. /dev/console is owned by the
    // active GUI login, which is the only local user allowed to feed audio.
    struct stat console = {};
    if (::stat("/dev/console", &console) == 0 && console.st_uid != 0) {
        return console.st_uid;
    }
    return getuid();
}

extern AudioServerPlugInDriverInterface gInterface;
AudioServerPlugInDriverInterface* gInterfacePointer = &gInterface;
AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

bool validDriver(AudioServerPlugInDriverRef driver) { return driver == gDriver; }
bool validObject(AudioObjectID object) {
    return object == kPluginObject || object == kDeviceObject || object == kStreamObject;
}

// Keep this diagnostic deliberately bounded. A client first asks HasProperty
// before it reads a value, so it gives us the exact standard HAL capability
// an application needs without changing the driver's advertised behaviour.
void traceUnsupportedDeviceProperty(pid_t clientPID,
                                    const AudioObjectPropertyAddress* address) {
    if (address == nullptr ||
        gUnsupportedPropertyLogCount.fetch_add(1, std::memory_order_relaxed) >= 64) {
        return;
    }
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
                     "CodexMic unsupported device property: pid=%{public}d selector=%{public}u scope=%{public}u element=%{public}u",
                     clientPID, address->mSelector, address->mScope, address->mElement);
}

AudioStreamBasicDescription streamFormat() {
    AudioStreamBasicDescription format = {};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = AudioFormatFlags(kAudioFormatFlagIsFloat) |
                          AudioFormatFlags(kAudioFormatFlagsNativeEndian) |
                          AudioFormatFlags(kAudioFormatFlagIsPacked);
    format.mBytesPerPacket = sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32);
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 32;
    return format;
}

template <typename T>
OSStatus writeScalar(const T& value, UInt32 available, UInt32* written,
                     void* output) {
    if (available < sizeof(T) || output == nullptr || written == nullptr) {
        return kAudioHardwareBadPropertySizeError;
    }
    *static_cast<T*>(output) = value;
    *written = sizeof(T);
    return noErr;
}

OSStatus writeString(CFStringRef value, UInt32 available, UInt32* written,
                     void* output) {
    if (available < sizeof(CFStringRef) || output == nullptr || written == nullptr) {
        return kAudioHardwareBadPropertySizeError;
    }
    CFRetain(value);
    *static_cast<CFStringRef*>(output) = value;
    *written = sizeof(CFStringRef);
    return noErr;
}

UInt32 propertySize(AudioObjectID object, const AudioObjectPropertyAddress& address) {
    switch (address.mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            return sizeof(AudioClassID);
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            return sizeof(CFStringRef);
        case kAudioObjectPropertyOwnedObjects:
            if (object == kPluginObject) return sizeof(AudioObjectID);
            if (object == kDeviceObject && address.mScope != kAudioObjectPropertyScopeOutput)
                return sizeof(AudioObjectID);
            return 0;
        default:
            break;
    }
    if (object == kPluginObject) {
        switch (address.mSelector) {
            case kAudioPlugInPropertyDeviceList:
                return sizeof(AudioObjectID);
            case kAudioPlugInPropertyTranslateUIDToDevice:
                return sizeof(AudioObjectID);
            case kAudioPlugInPropertyResourceBundle:
                return sizeof(CFStringRef);
            default:
                return 0;
        }
    }
    if (object == kDeviceObject) {
        switch (address.mSelector) {
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                return sizeof(CFStringRef);
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyBufferFrameSize:
            case kAudioDevicePropertyUsesVariableBufferFrameSizes:
            case kAudioDevicePropertyIsHidden:
                return sizeof(UInt32);
            case kAudioDevicePropertyRelatedDevices:
                return sizeof(AudioObjectID);
            case kAudioDevicePropertyStreams:
                return address.mScope == kAudioObjectPropertyScopeOutput ? 0
                                                                        : sizeof(AudioObjectID);
            case kAudioObjectPropertyControlList:
                return 0;
            case kAudioDevicePropertyNominalSampleRate:
                return sizeof(Float64);
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyBufferFrameSizeRange:
                return sizeof(AudioValueRange);
            default:
                return 0;
        }
    }
    if (object == kStreamObject) {
        switch (address.mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
                return sizeof(UInt32);
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                return sizeof(AudioStreamBasicDescription);
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return sizeof(AudioStreamRangedDescription);
            default:
                return 0;
        }
    }
    return 0;
}

HRESULT QueryInterface(void* driver, REFIID uuid, LPVOID* output) {
    if (driver != gDriver || output == nullptr) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(nullptr, uuid);
    if (requested == nullptr) return kAudioHardwareIllegalOperationError;
    const bool supported = CFEqual(requested, IUnknownUUID) ||
                           CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!supported) return E_NOINTERFACE;
    gRefCount.fetch_add(1);
    *output = gDriver;
    return S_OK;
}

ULONG AddRef(void* driver) {
    if (driver != gDriver) return 0;
    return gRefCount.fetch_add(1) + 1;
}

ULONG Release(void* driver) {
    if (driver != gDriver) return 0;
    ULONG current = gRefCount.load();
    while (current > 0 && !gRefCount.compare_exchange_weak(current, current - 1)) {}
    return current == 0 ? 0 : current - 1;
}

OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (!validDriver(driver)) return kAudioHardwareBadObjectError;
    gHost = host;
    mach_timebase_info_data_t timebase = {};
    mach_timebase_info(&timebase);
    gHostTicksPerFrame = (1'000'000'000.0 / kSampleRate) *
                         static_cast<double>(timebase.denom) /
                         static_cast<double>(timebase.numer);
    // The client runs as the logged-in user while this code runs as
    // _coreaudiod. Publish a shared path and rely on getpeereid() in the
    // server to admit only the active console user.
    constexpr const char* path = "/tmp/codex-mic.sock";
    gServer = std::make_unique<UnixAudioServer<kRingCapacity>>(
        path, gRing, consoleUserID(), 0666
    );
    if (!gServer->start()) return kAudioHardwareUnspecifiedError;
    return noErr;
}

OSStatus UnsupportedCreate(AudioServerPlugInDriverRef, CFDictionaryRef,
                           const AudioServerPlugInClientInfo*, AudioObjectID*) {
    return kAudioHardwareUnsupportedOperationError;
}
OSStatus UnsupportedDestroy(AudioServerPlugInDriverRef, AudioObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}
OSStatus AddClient(AudioServerPlugInDriverRef driver, AudioObjectID object,
                   const AudioServerPlugInClientInfo*) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    return noErr;
}
OSStatus RemoveClient(AudioServerPlugInDriverRef driver, AudioObjectID object,
                      const AudioServerPlugInClientInfo*) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    return noErr;
}
OSStatus ConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID object,
                             UInt64, void*) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    return noErr;
}

Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t clientPID,
                    const AudioObjectPropertyAddress* address) {
    if (!validDriver(driver) || !validObject(object) || address == nullptr) return false;
    const bool supported = propertySize(object, *address) > 0;
    if (!supported && object == kDeviceObject) {
        traceUnsupportedDeviceProperty(clientPID, address);
    }
    return supported;
}

OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID object,
                            pid_t, const AudioObjectPropertyAddress* address,
                            Boolean* settable) {
    if (!validDriver(driver) || !validObject(object)) return kAudioHardwareBadObjectError;
    if (address == nullptr || settable == nullptr || propertySize(object, *address) == 0)
        return kAudioHardwareUnknownPropertyError;
    *settable = false;
    return noErr;
}

OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID object,
                             pid_t, const AudioObjectPropertyAddress* address, UInt32,
                             const void*, UInt32* size) {
    if (!validDriver(driver) || !validObject(object)) return kAudioHardwareBadObjectError;
    if (address == nullptr || size == nullptr) return kAudioHardwareIllegalOperationError;
    const UInt32 result = propertySize(object, *address);
    if (result == 0 && address->mSelector != kAudioObjectPropertyOwnedObjects &&
        address->mSelector != kAudioObjectPropertyControlList &&
        address->mSelector != kAudioDevicePropertyStreams) {
        return kAudioHardwareUnknownPropertyError;
    }
    *size = result;
    return noErr;
}

OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t,
                         const AudioObjectPropertyAddress* address,
                         UInt32 qualifierSize, const void* qualifier, UInt32 available,
                         UInt32* written, void* output) {
    if (!validDriver(driver) || !validObject(object)) return kAudioHardwareBadObjectError;
    if (address == nullptr || written == nullptr) return kAudioHardwareIllegalOperationError;
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            AudioClassID value = kAudioObjectClassID;
            return writeScalar(value, available, written, output);
        }
        case kAudioObjectPropertyClass: {
            AudioClassID value = object == kPluginObject
                ? AudioClassID(kAudioPlugInClassID)
                : object == kDeviceObject ? AudioClassID(kAudioDeviceClassID)
                                          : AudioClassID(kAudioStreamClassID);
            return writeScalar(value, available, written, output);
        }
        case kAudioObjectPropertyOwner: {
            AudioObjectID value = object == kPluginObject    ? kAudioObjectUnknown
                                  : object == kDeviceObject ? kPluginObject
                                                            : kDeviceObject;
            return writeScalar(value, available, written, output);
        }
        case kAudioObjectPropertyName:
            return writeString(object == kPluginObject ? CFSTR("Codex Mic Plug-In")
                               : object == kDeviceObject ? CFSTR("Codex Mic")
                                                         : CFSTR("Codex Mic Input"),
                               available, written, output);
        case kAudioObjectPropertyManufacturer:
            return writeString(CFSTR("Codex Companion"), available, written, output);
        case kAudioObjectPropertyOwnedObjects:
            if (object == kPluginObject)
                return writeScalar(kDeviceObject, available, written, output);
            if (object == kDeviceObject && address->mScope != kAudioObjectPropertyScopeOutput)
                return writeScalar(kStreamObject, available, written, output);
            *written = 0;
            return noErr;
        default:
            break;
    }
    if (object == kPluginObject) {
        if (address->mSelector == kAudioPlugInPropertyDeviceList)
            return writeScalar(kDeviceObject, available, written, output);
        if (address->mSelector == kAudioPlugInPropertyResourceBundle)
            return writeString(CFSTR(""), available, written, output);
        if (address->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
            if (qualifierSize != sizeof(CFStringRef) || qualifier == nullptr)
                return kAudioHardwareBadPropertySizeError;
            const CFStringRef uid = *static_cast<const CFStringRef*>(qualifier);
            const AudioObjectID value =
                CFEqual(uid, CFSTR("com.codexcompanion.mic.device"))
                    ? kDeviceObject
                    : kAudioObjectUnknown;
            return writeScalar(value, available, written, output);
        }
    } else if (object == kDeviceObject) {
        switch (address->mSelector) {
            case kAudioDevicePropertyDeviceUID:
                return writeString(CFSTR("com.codexcompanion.mic.device"), available,
                                   written, output);
            case kAudioDevicePropertyModelUID:
                return writeString(CFSTR("com.codexcompanion.mic.model"), available,
                                   written, output);
            case kAudioDevicePropertyTransportType:
                return writeScalar<UInt32>(kReportedTransportType, available, written,
                                           output);
            case kAudioDevicePropertyClockDomain:
                return writeScalar<UInt32>(0, available, written, output);
            case kAudioDevicePropertyDeviceIsAlive:
                return writeScalar<UInt32>(1, available, written, output);
            case kAudioDevicePropertyDeviceIsRunning:
                return writeScalar<UInt32>(gRunningClients.load() > 0, available,
                                           written, output);
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                return writeScalar<UInt32>(
                    address->mScope == kAudioObjectPropertyScopeInput ? 1 : 0,
                    available, written, output);
            case kAudioDevicePropertyRelatedDevices:
                return writeScalar(kDeviceObject, available, written, output);
            case kAudioDevicePropertyStreams:
                if (address->mScope == kAudioObjectPropertyScopeOutput) {
                    *written = 0;
                    return noErr;
                }
                return writeScalar(kStreamObject, available, written, output);
            case kAudioObjectPropertyControlList:
                *written = 0;
                return noErr;
            case kAudioDevicePropertyNominalSampleRate:
                return writeScalar<Float64>(kSampleRate, available, written, output);
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange range = {kSampleRate, kSampleRate};
                return writeScalar(range, available, written, output);
            }
            case kAudioDevicePropertyBufferFrameSize:
            case kAudioDevicePropertyZeroTimeStampPeriod:
                return writeScalar<UInt32>(kBufferFrames, available, written, output);
            case kAudioDevicePropertyBufferFrameSizeRange: {
                AudioValueRange range = {64, 2'048};
                return writeScalar(range, available, written, output);
            }
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyUsesVariableBufferFrameSizes:
            case kAudioDevicePropertyIsHidden:
                return writeScalar<UInt32>(0, available, written, output);
            default:
                break;
        }
    } else if (object == kStreamObject) {
        switch (address->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyStartingChannel:
                return writeScalar<UInt32>(1, available, written, output);
            case kAudioStreamPropertyTerminalType:
                return writeScalar<UInt32>(kAudioStreamTerminalTypeMicrophone, available,
                                           written, output);
            case kAudioStreamPropertyLatency:
                return writeScalar<UInt32>(0, available, written, output);
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                const auto format = streamFormat();
                return writeScalar(format, available, written, output);
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription description = {};
                description.mFormat = streamFormat();
                description.mSampleRateRange = {kSampleRate, kSampleRate};
                return writeScalar(description, available, written, output);
            }
            default:
                break;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t,
                         const AudioObjectPropertyAddress*, UInt32, const void*, UInt32,
                         const void*) {
    return validDriver(driver) && validObject(object)
               ? kAudioHardwareUnsupportedOperationError
               : kAudioHardwareBadObjectError;
}

OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    if (gRunningClients.fetch_add(1) == 0) {
        std::lock_guard<std::mutex> lock(gTimeMutex);
        gAnchorHostTime = mach_absolute_time();
        gTimestampNumber = 0;
    }
    return noErr;
}

OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    UInt32 running = gRunningClients.load();
    while (running > 0 && !gRunningClients.compare_exchange_weak(running, running - 1)) {}
    return noErr;
}

OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32,
                          Float64* sampleTime, UInt64* hostTime, UInt64* seed) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    if (sampleTime == nullptr || hostTime == nullptr || seed == nullptr)
        return kAudioHardwareIllegalOperationError;
    std::lock_guard<std::mutex> lock(gTimeMutex);
    const UInt64 now = mach_absolute_time();
    const double ticksPerPeriod = gHostTicksPerFrame * kBufferFrames;
    const UInt64 elapsedPeriods = ticksPerPeriod > 0
        ? static_cast<UInt64>((now - gAnchorHostTime) / ticksPerPeriod)
        : 0;
    if (elapsedPeriods > gTimestampNumber) gTimestampNumber = elapsedPeriods;
    *sampleTime = static_cast<Float64>(gTimestampNumber * kBufferFrames);
    *hostTime = gAnchorHostTime + static_cast<UInt64>(gTimestampNumber * ticksPerPeriod);
    *seed = 1;
    return noErr;
}

OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32,
                           UInt32 operation, Boolean* willDo, Boolean* inPlace) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    if (willDo != nullptr) *willDo = operation == kAudioServerPlugInIOOperationReadInput;
    if (inPlace != nullptr) *inPlace = true;
    return noErr;
}

OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32,
                          UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    return noErr;
}

OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device,
                       AudioObjectID stream, UInt32, UInt32 operation, UInt32 frames,
                       const AudioServerPlugInIOCycleInfo*, void* mainBuffer, void*) {
    if (!validDriver(driver) || device != kDeviceObject || stream != kStreamObject)
        return kAudioHardwareBadObjectError;
    if (operation != kAudioServerPlugInIOOperationReadInput) return noErr;
    if (mainBuffer == nullptr) return kAudioHardwareIllegalOperationError;
    gRing.read(static_cast<Float32*>(mainBuffer), frames);
    return noErr;
}

OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32,
                        UInt32, UInt32, const AudioServerPlugInIOCycleInfo*) {
    if (!validDriver(driver) || object != kDeviceObject) return kAudioHardwareBadObjectError;
    return noErr;
}

AudioServerPlugInDriverInterface gInterface = {
    nullptr,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    UnsupportedCreate,
    UnsupportedDestroy,
    AddClient,
    RemoveClient,
    ConfigurationChange,
    ConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
}  // namespace

extern "C" __attribute__((visibility("default"))) void* CodexMic_Create(
    CFAllocatorRef, CFUUIDRef requestedType) {
    return CFEqual(requestedType, kAudioServerPlugInTypeUUID) ? gDriver : nullptr;
}
