import XCTest
@testable import CodexCompanionCore

final class PTTControllerTests: XCTestCase {
    func testHoldProfileKeepsShortcutDownUntilButtonRelease() throws {
        let dependencies = Dependencies()
        let controller = dependencies.makeController()
        let profile = makeProfile(mode: .hold)

        try controller.buttonDown(profile: profile)
        try controller.buttonUp()

        XCTAssertEqual(dependencies.route.events, [.prepare, .restore])
        XCTAssertEqual(dependencies.audio.events, [.start(preRollMs: 300), .stop(postRollMs: 200)])
        XCTAssertEqual(dependencies.keys.events, [
            .press(profile.startShortcut),
            .release(profile.startShortcut),
        ])
        XCTAssertEqual(controller.state, .idle)
    }

    func testTogglePairTapsSameShortcutAtBothEdges() throws {
        let dependencies = Dependencies()
        let controller = dependencies.makeController()
        let profile = makeProfile(mode: .togglePair)

        try controller.buttonDown(profile: profile)
        try controller.buttonUp()

        XCTAssertEqual(dependencies.keys.events, [
            .tap(profile.startShortcut),
            .tap(profile.startShortcut),
        ])
    }

    func testSeparateModeUsesDedicatedStopShortcut() throws {
        let dependencies = Dependencies()
        let controller = dependencies.makeController()
        let stop = KeyboardShortcut(keyCode: 8, modifiers: [.control])
        var profile = makeProfile(mode: .separate)
        profile.stopShortcut = stop

        try controller.buttonDown(profile: profile)
        try controller.buttonUp()

        XCTAssertEqual(dependencies.keys.events, [
            .tap(profile.startShortcut),
            .tap(stop),
        ])
    }

    func testShortcutFailurePerformsSafeCleanup() throws {
        let dependencies = Dependencies()
        dependencies.keys.failOnNextEvent = true
        let controller = dependencies.makeController()

        XCTAssertThrowsError(try controller.buttonDown(profile: makeProfile(mode: .hold)))

        XCTAssertEqual(dependencies.audio.events, [.start(preRollMs: 300), .cancel])
        XCTAssertEqual(dependencies.route.events, [.prepare, .restore])
        XCTAssertEqual(dependencies.keys.events, [.release(makeProfile(mode: .hold).startShortcut)])
        XCTAssertEqual(controller.state, .failed)
    }

    func testDuplicateButtonDownDoesNotStartSecondSession() throws {
        let dependencies = Dependencies()
        let controller = dependencies.makeController()
        let profile = makeProfile(mode: .hold)

        try controller.buttonDown(profile: profile)
        XCTAssertThrowsError(try controller.buttonDown(profile: profile)) { error in
            XCTAssertEqual(error as? PTTError, .sessionAlreadyActive)
        }

        XCTAssertEqual(dependencies.audio.events, [.start(preRollMs: 300)])
    }

    func testDeferredFinishKeepsRouteAndRejectsNewSessionUntilGraceEnds() throws {
        let dependencies = Dependencies()
        let controller = dependencies.makeController()
        let profile = makeProfile(mode: .hold)

        try controller.buttonDown(profile: profile)
        try controller.buttonUp(deferRouteRestore: true)

        XCTAssertEqual(controller.state, .finishing(profileID: profile.id))
        XCTAssertEqual(dependencies.route.events, [.prepare])
        XCTAssertThrowsError(try controller.buttonDown(profile: profile))

        controller.finishDeferredRestore()
        XCTAssertEqual(dependencies.route.events, [.prepare, .restore])
        XCTAssertEqual(controller.state, .idle)
    }

    private func makeProfile(mode: VoiceTriggerMode) -> VoiceShortcutProfile {
        VoiceShortcutProfile(
            id: "test",
            displayName: "Test",
            matchPolicy: .always,
            triggerMode: mode,
            startShortcut: KeyboardShortcut(keyCode: 9, modifiers: [.command])
        )
    }
}

private final class Dependencies {
    let route = RecordingRoute()
    let audio = RecordingAudio()
    let keys = RecordingKeys()

    func makeController() -> PTTController {
        PTTController(audio: audio, route: route, keys: keys)
    }
}

private final class RecordingRoute: AudioRouteManaging {
    enum Event: Equatable { case prepare, restore }
    var events: [Event] = []
    func prepareCodexMic() throws { events.append(.prepare) }
    func restorePreviousRoute() { events.append(.restore) }
}

private final class RecordingAudio: AudioStreaming {
    enum Event: Equatable {
        case start(preRollMs: UInt32)
        case stop(postRollMs: UInt32)
        case cancel
    }
    var events: [Event] = []
    func start(preRollMs: UInt32) throws { events.append(.start(preRollMs: preRollMs)) }
    func stop(postRollMs: UInt32) { events.append(.stop(postRollMs: postRollMs)) }
    func cancel() { events.append(.cancel) }
}

private final class RecordingKeys: ShortcutEmitting {
    enum Event: Equatable {
        case press(KeyboardShortcut)
        case release(KeyboardShortcut)
        case tap(KeyboardShortcut)
    }
    var events: [Event] = []
    var failOnNextEvent = false

    func press(_ shortcut: KeyboardShortcut) throws { try record(.press(shortcut)) }
    func release(_ shortcut: KeyboardShortcut) throws { try record(.release(shortcut)) }
    func tap(_ shortcut: KeyboardShortcut) throws { try record(.tap(shortcut)) }

    private func record(_ event: Event) throws {
        if failOnNextEvent {
            failOnNextEvent = false
            throw PTTError.shortcutEmissionFailed
        }
        events.append(event)
    }
}
