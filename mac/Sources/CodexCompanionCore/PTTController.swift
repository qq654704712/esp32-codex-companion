import Foundation

public protocol AudioRouteManaging: AnyObject {
    func prepareCodexMic() throws
    func restorePreviousRoute()
}

public protocol AudioStreaming: AnyObject {
    func start(preRollMs: UInt32) throws
    func stop(postRollMs: UInt32)
    func cancel()
}

public protocol ShortcutEmitting: AnyObject {
    func press(_ shortcut: KeyboardShortcut) throws
    func release(_ shortcut: KeyboardShortcut) throws
    func tap(_ shortcut: KeyboardShortcut) throws
}

public enum PTTSessionState: Equatable, Sendable {
    case idle
    case active(profileID: String)
    case finishing(profileID: String)
    case failed
}

public enum PTTError: Error, Equatable {
    case sessionAlreadyActive
    case noActiveSession
    case missingStopShortcut
    case shortcutEmissionFailed
}

public final class PTTController {
    public private(set) var state: PTTSessionState = .idle

    private let audio: AudioStreaming
    private let route: AudioRouteManaging
    private let keys: ShortcutEmitting
    private var activeProfile: VoiceShortcutProfile?

    public init(
        audio: AudioStreaming,
        route: AudioRouteManaging,
        keys: ShortcutEmitting
    ) {
        self.audio = audio
        self.route = route
        self.keys = keys
    }

    public func buttonDown(profile: VoiceShortcutProfile) throws {
        guard state == .idle else { throw PTTError.sessionAlreadyActive }
        do {
            try audio.start(preRollMs: profile.preRollMs)
            try route.prepareCodexMic()
            switch profile.triggerMode {
            case .hold:
                do {
                    try keys.press(profile.startShortcut)
                } catch {
                    try? keys.release(profile.startShortcut)
                    throw error
                }
            case .togglePair, .separate:
                try keys.tap(profile.startShortcut)
            }
            activeProfile = profile
            state = .active(profileID: profile.id)
        } catch {
            audio.cancel()
            route.restorePreviousRoute()
            activeProfile = nil
            state = .failed
            throw error
        }
    }

    public func buttonUp(deferRouteRestore: Bool = false) throws {
        guard let profile = activeProfile else { throw PTTError.noActiveSession }
        audio.stop(postRollMs: profile.postRollMs)
        do {
            switch profile.triggerMode {
            case .hold:
                try keys.release(profile.startShortcut)
            case .togglePair:
                try keys.tap(profile.startShortcut)
            case .separate:
                guard let stopShortcut = profile.stopShortcut else {
                    throw PTTError.missingStopShortcut
                }
                try keys.tap(stopShortcut)
            }
            activeProfile = nil
            if deferRouteRestore {
                state = .finishing(profileID: profile.id)
            } else {
                route.restorePreviousRoute()
                state = .idle
            }
        } catch {
            try? keys.release(profile.startShortcut)
            audio.cancel()
            route.restorePreviousRoute()
            activeProfile = nil
            state = .failed
            throw error
        }
    }

    public func finishDeferredRestore() {
        guard case .finishing = state else { return }
        route.restorePreviousRoute()
        state = .idle
    }

    public func cancel() {
        if let profile = activeProfile, profile.triggerMode == .hold {
            try? keys.release(profile.startShortcut)
        }
        audio.cancel()
        route.restorePreviousRoute()
        activeProfile = nil
        state = .idle
    }

    public func resetFailure() {
        if state == .failed { state = .idle }
    }
}
