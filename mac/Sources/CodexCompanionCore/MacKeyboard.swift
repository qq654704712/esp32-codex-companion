#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

public extension KeyboardModifiers {
    init(cgEventFlags flags: CGEventFlags) {
        self = []
        if flags.contains(.maskCommand) { insert(.command) }
        if flags.contains(.maskAlternate) { insert(.option) }
        if flags.contains(.maskControl) { insert(.control) }
        if flags.contains(.maskShift) { insert(.shift) }
        if flags.contains(.maskSecondaryFn) { insert(.fn) }
    }

    var cgEventFlags: CGEventFlags {
        var result: CGEventFlags = []
        if contains(.command) { result.insert(.maskCommand) }
        if contains(.option) { result.insert(.maskAlternate) }
        if contains(.control) { result.insert(.maskControl) }
        if contains(.shift) { result.insert(.maskShift) }
        if contains(.fn) { result.insert(.maskSecondaryFn) }
        return result
    }
}

public enum ShortcutRecorderError: Error, Equatable {
    case accessibilityPermissionMissing
    case eventTapCreationFailed
    case timedOut
}

public final class ShortcutRecorder {
    private var captured: KeyboardShortcut?
    private var runLoop: CFRunLoop?

    public init() {}

    public func record(timeout: TimeInterval = 15) throws -> KeyboardShortcut {
        guard CGEventShortcutEmitter.isAccessibilityTrusted else {
            throw ShortcutRecorderError.accessibilityPermissionMissing
        }
        captured = nil
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(userInfo).takeUnretainedValue()
                recorder.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw ShortcutRecorderError.eventTapCreationFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw ShortcutRecorderError.eventTapCreationFailed
        }
        let current = CFRunLoopGetCurrent()
        runLoop = current
        CFRunLoopAddSource(current, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRunInMode(.defaultMode, timeout, false)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(current, source, .defaultMode)
        runLoop = nil
        guard let captured else { throw ShortcutRecorderError.timedOut }
        return captured
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = KeyboardModifiers(cgEventFlags: event.flags)
        if type == .keyDown {
            captured = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        } else if type == .flagsChanged, keyCode == 63, modifiers.contains(.fn) {
            captured = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers, modifierOnly: true)
        }
        if captured != nil, let runLoop { CFRunLoopStop(runLoop) }
    }
}

public enum ShortcutEmissionError: Error, Equatable {
    case accessibilityPermissionMissing
    case eventCreationFailed
}

public final class CGEventShortcutEmitter: ShortcutEmitting {
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func press(_ shortcut: KeyboardShortcut) throws {
        try post(shortcut, keyDown: true)
    }

    public func release(_ shortcut: KeyboardShortcut) throws {
        try post(shortcut, keyDown: false)
    }

    public func tap(_ shortcut: KeyboardShortcut) throws {
        try press(shortcut)
        try release(shortcut)
    }

    private func post(_ shortcut: KeyboardShortcut, keyDown: Bool) throws {
        guard Self.isAccessibilityTrusted else {
            throw ShortcutEmissionError.accessibilityPermissionMissing
        }
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: keyDown
        ) else {
            throw ShortcutEmissionError.eventCreationFailed
        }
        event.flags = keyDown ? shortcut.modifiers.cgEventFlags : []
        event.post(tap: .cghidEventTap)
    }
}
#endif
