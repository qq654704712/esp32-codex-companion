import XCTest
@testable import CodexCompanionCore

final class VoiceShortcutProfileTests: XCTestCase {
    func testActiveInputSourceProfileWinsOverAlwaysProfile() throws {
        let shortcut = KeyboardShortcut(keyCode: 9, modifiers: [.command, .option])
        let active = VoiceShortcutProfile(
            id: "active",
            displayName: "Active source",
            matchPolicy: .activeInputSource,
            inputSourceIDs: ["com.example.input"],
            triggerMode: .hold,
            startShortcut: shortcut
        )
        let fallback = VoiceShortcutProfile(
            id: "fallback",
            displayName: "Fallback",
            matchPolicy: .always,
            triggerMode: .togglePair,
            startShortcut: shortcut
        )

        let selected = VoiceProfileResolver().resolve(
            profiles: [fallback, active],
            activeInputSourceID: "com.example.input"
        )

        XCTAssertEqual(selected?.id, "active")
    }

    func testProfileRoundTripsWithoutSavingCharacters() throws {
        let profile = VoiceShortcutProfile(
            id: "separate",
            displayName: "Separate start stop",
            matchPolicy: .always,
            triggerMode: .separate,
            startShortcut: KeyboardShortcut(keyCode: 63, modifiers: [.fn], modifierOnly: true),
            stopShortcut: KeyboardShortcut(keyCode: 9, modifiers: [.control, .option, .command]),
            preRollMs: 300,
            postRollMs: 200,
            restoreInputSource: true
        )

        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(VoiceShortcutProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
        XCTAssertFalse(json.contains("character"))
    }

    func testBootFnDefaultIsModifierOnlyHoldProfile() {
        let profile = VoiceShortcutProfile.bootFnDefault

        XCTAssertEqual(profile.triggerMode, .hold)
        XCTAssertEqual(profile.startShortcut.keyCode, 63)
        XCTAssertEqual(profile.startShortcut.modifiers, [.fn])
        XCTAssertTrue(profile.startShortcut.modifierOnly)
        XCTAssertFalse(profile.restoreInputSource)
    }
}
