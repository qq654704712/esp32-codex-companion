import Foundation
import XCTest
@testable import CodexCompanionCore

final class BLEControlFramerTests: XCTestCase {
    func testReassembles() throws {
        let source = Data((0..<512).map { UInt8($0 & 0xFF) })
        let fragments = try BLEControlFramer.fragment(source, frameID: 0x1234)
        XCTAssertEqual(fragments.count, 3)
        XCTAssertTrue(fragments.allSatisfy { $0.count <= 244 })
        var reassembler = BLEControlReassembler()
        var result: Data?
        for fragment in fragments { result = try reassembler.accept(fragment) ?? result }
        XCTAssertEqual(result, source)
    }

    func testRejectsOutOfOrder() throws {
        let fragments = try BLEControlFramer.fragment(Data(repeating: 1, count: 300), frameID: 4)
        var reassembler = BLEControlReassembler()
        XCTAssertThrowsError(try reassembler.accept(fragments[1])) { error in
            XCTAssertTrue(error is BLEControlFramingError)
        }
    }
}
