import CoreGraphics
import XCTest
@testable import CodexCompanionCore

final class VoiceProfileStoreTests: XCTestCase {
    func testProfilesPersistAndReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let profile = VoiceShortcutProfile(
            id: "profile",
            displayName: "Voice profile",
            matchPolicy: .activeInputSource,
            inputSourceIDs: ["com.example.input"],
            triggerMode: .hold,
            startShortcut: KeyboardShortcut(keyCode: 63, modifiers: [.fn], modifierOnly: true)
        )

        try store.save([profile])

        XCTAssertEqual(try store.load(), [profile])
    }

    func testSeparateProfileRequiresStopShortcut() {
        let profile = VoiceShortcutProfile(
            id: "invalid",
            displayName: "Invalid",
            matchPolicy: .always,
            triggerMode: .separate,
            startShortcut: KeyboardShortcut(keyCode: 9)
        )

        XCTAssertThrowsError(try VoiceProfileValidator.validate(profile)) { error in
            XCTAssertEqual(error as? VoiceProfileValidationError, .missingStopShortcut)
        }
    }

    func testLegacyProfileDefaultsSubmissionGraceToTwoPointFiveSeconds() throws {
        let json = Data("""
        [{"id":"legacy","displayName":"Legacy","matchPolicy":"always","inputSourceIDs":[],"triggerMode":"hold","startShortcut":{"keyCode":9,"modifiers":1,"modifierOnly":false},"preRollMs":300,"postRollMs":200,"restoreInputSource":true,"isEnabled":true}]
        """.utf8)

        let profiles = try JSONDecoder().decode([VoiceShortcutProfile].self, from: json)

        XCTAssertEqual(profiles.first?.commitGraceMs, 2_500)
    }

    func testKeyboardModifiersMapToCGEventFlags() {
        let flags = KeyboardModifiers([.command, .option, .fn]).cgEventFlags

        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskAlternate))
        XCTAssertTrue(flags.contains(.maskSecondaryFn))
        XCTAssertFalse(flags.contains(.maskShift))
    }

    func testCGEventFlagsMapBackToKeyboardModifiers() {
        let modifiers = KeyboardModifiers(
            cgEventFlags: [.maskCommand, .maskControl, .maskSecondaryFn]
        )

        XCTAssertEqual(modifiers, [.command, .control, .fn])
    }
}
