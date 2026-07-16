#if os(macOS)
import Foundation
import XCTest
@testable import CodexCompanionCore

final class CodexMicSocketClientTests: XCTestCase {
    func testDefaultSocketPathIsSharedWithTheCoreAudioDriver() {
        XCTAssertEqual(CodexMicSocketClient().socketPath, "/tmp/codex-mic.sock")
    }

    func testSessionAllowsDriverStartupBeforeSocketExists() throws {
        let path = "/tmp/codex-mic-test-\(UUID().uuidString).sock"
        let client = CodexMicSocketClient(socketPath: path)

        // The HAL endpoint is created only after an input application starts
        // IO. Beginning a PTT session must not fail in that short interval.
        XCTAssertNoThrow(try client.beginSession())
        XCTAssertNoThrow(try client.write(samples: [0, 0, 0]))
        client.disconnect()
    }
}
#endif
