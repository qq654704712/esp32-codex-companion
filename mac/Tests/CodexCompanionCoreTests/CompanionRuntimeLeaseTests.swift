import Foundation
import XCTest
@testable import CodexCompanionCore

final class CompanionRuntimeLeaseTests: XCTestCase {
    func testOnlyOneRuntimeCanHoldLeaseAtATime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lockURL = directory.appendingPathComponent("runtime.lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try XCTUnwrap(CompanionRuntimeLease.acquire(lockURL: lockURL))
        XCTAssertNil(CompanionRuntimeLease.acquire(lockURL: lockURL))
        first.release()
        XCTAssertNotNil(CompanionRuntimeLease.acquire(lockURL: lockURL))
    }
}
