import Foundation
import XCTest
@testable import CodexCompanionCore

final class ApplicationKeyManagerTests: XCTestCase {
    func testCreatesAndReuses() throws {
        let storage = MemoryKeyStorage()
        let expected = Data(repeating: 0xA5, count: 32)
        let manager = ApplicationKeyManager(storage: storage) { expected }

        XCTAssertEqual(try manager.loadOrCreate(), expected)
        XCTAssertEqual(try manager.loadOrCreate(), expected)
        XCTAssertEqual(storage.saveCount, 1)
    }
}

private final class MemoryKeyStorage: ApplicationKeyStorage {
    var value: Data?
    var saveCount = 0

    func load() throws -> Data? { value }
    func save(_ value: Data) throws {
        self.value = value
        saveCount += 1
    }
}
