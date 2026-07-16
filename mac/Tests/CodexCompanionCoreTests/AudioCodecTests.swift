import XCTest
@testable import CodexCompanionCore

final class AudioCodecTests: XCTestCase {
    func testSilentADPCMFrameDecodesTo320Samples() throws {
        let packet = makePacket(sequence: 0x1234, predictor: 0, index: 0, payload: Data(repeating: 0, count: 160))

        let frame = try ADPCMFrameCodec.decode(packet)

        XCTAssertEqual(frame.sequence, 0x1234)
        XCTAssertEqual(frame.samples.count, 320)
        XCTAssertTrue(frame.samples.allSatisfy { $0 == 0 })
    }

    func testLowNibbleIsDecodedBeforeHighNibble() throws {
        var payload = Data(repeating: 0, count: 160)
        payload[0] = 0x01

        let frame = try ADPCMFrameCodec.decode(
            makePacket(sequence: 1, predictor: 0, index: 0, payload: payload)
        )

        XCTAssertEqual(Array(frame.samples.prefix(2)), [1, 1])
    }

    func testFrameGapProducesOneSilentFrame() throws {
        var sequencer = AudioFrameSequencer(samplesPerFrame: 320)

        XCTAssertEqual(try sequencer.accept(sequence: 5), [])
        XCTAssertEqual(try sequencer.accept(sequence: 7), [Int16](repeating: 0, count: 320))
        XCTAssertThrowsError(try sequencer.accept(sequence: 7))
    }

    func testThreeTimesResamplerPreservesConstantSignal() {
        var resampler = LinearResampler16kTo48k()

        let output = resampler.process([1_000, 1_000])

        XCTAssertEqual(output.count, 6)
        for value in output {
            XCTAssertEqual(value, Float(1_000) / Float(Int16.max), accuracy: 0.000_001)
        }
    }

    private func makePacket(sequence: UInt16, predictor: Int16, index: UInt8, payload: Data) -> Data {
        var result = Data([
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
            UInt8(bitPattern: Int8(truncatingIfNeeded: predictor >> 8)), UInt8(truncatingIfNeeded: predictor),
            index, 0,
        ])
        result.append(payload)
        return result
    }
}
