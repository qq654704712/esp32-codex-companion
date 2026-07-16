import XCTest
@testable import CodexCompanionCore

final class WiFiTCPFramerTests: XCTestCase {
    func testReassemblesFragmentedAndCoalescedFrames() throws {
        let first = try WiFiTCPFramer.encode(Data(repeating: 0x11, count: 60))
        let second = try WiFiTCPFramer.encode(Data(repeating: 0x22, count: 80))
        var framer = WiFiTCPFramer()

        XCTAssertTrue(try framer.append(first.prefix(7)).isEmpty)
        XCTAssertEqual(
            try framer.append(first.dropFirst(7) + second),
            [Data(repeating: 0x11, count: 60), Data(repeating: 0x22, count: 80)]
        )
    }

    func testRejectsZeroLengthFrame() {
        var framer = WiFiTCPFramer()
        XCTAssertThrowsError(try framer.append(Data([0, 0]))) {
            XCTAssertEqual($0 as? WiFiWireCodecError, .invalidPayloadLength)
        }
    }
}
