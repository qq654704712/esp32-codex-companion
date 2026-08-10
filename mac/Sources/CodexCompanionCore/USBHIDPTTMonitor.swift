#if os(macOS)
import ApplicationServices
import Foundation

/// Receives the dedicated F13 edge from the Companion USB HID interface.
/// The hardware only identifies the physical PTT boundary; shortcut choice
/// remains entirely in the Mac profile and can therefore support any IME.
@MainActor
public final class USBHIDPTTMonitor {
    // macOS virtual keycode corresponding to USB HID usage F13 (0x68).
    private static let f13KeyCode: Int64 = 105

    public var onButton: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    public func start() {
        guard tap == nil, CGEventShortcutEmitter.isAccessibilityTrusted else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<USBHIDPTTMonitor>
                    .fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }
        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.f13KeyCode else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            FileHandle.standardError.write(Data("[Codex HID] BOOT down\n".utf8))
            onButton?(true)
        } else if type == .keyUp {
            FileHandle.standardError.write(Data("[Codex HID] BOOT up\n".utf8))
            onButton?(false)
        }
        // F13 is reserved solely as the device's private transport key and
        // should never leak into the foreground editor.
        return nil
    }
}
#endif
