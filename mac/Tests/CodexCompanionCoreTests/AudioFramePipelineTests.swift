import XCTest
@testable import CodexCompanionCore

final class AudioFramePipelineTests: XCTestCase {
    func testDecodedFrameIsResampledAndWrittenToSink() throws {
        let sink = RecordingFloatSink()
        let pipeline = AudioFramePipeline(sink: sink)

        try pipeline.ingest(silentPacket(sequence: 1))

        XCTAssertEqual(sink.writes.count, 1)
        XCTAssertEqual(sink.writes[0].count, 960)
        XCTAssertTrue(sink.writes[0].allSatisfy { $0 == 0 })
    }

    func testMissingFrameIsInsertedBeforeCurrentFrame() throws {
        let sink = RecordingFloatSink()
        let pipeline = AudioFramePipeline(sink: sink)
        try pipeline.ingest(silentPacket(sequence: 8))

        try pipeline.ingest(silentPacket(sequence: 10))

        XCTAssertEqual(sink.writes[1].count, 1_920)
    }

    func testResetStartsANewPushToTalkSessionAtSequenceZero() throws {
        let sink = RecordingFloatSink()
        let pipeline = AudioFramePipeline(sink: sink)

        try pipeline.ingest(silentPacket(sequence: 42))
        pipeline.resetSession()
        try pipeline.ingest(silentPacket(sequence: 0))
        try pipeline.ingest(silentPacket(sequence: 1))

        XCTAssertEqual(sink.writes.count, 3)
        XCTAssertEqual(sink.writes[1].count, 960)
    }

    func testSequenceZeroThatRacesAheadOfPttDownIsDeferredUntilReset() throws {
        let sink = RecordingFloatSink()
        let pipeline = AudioFramePipeline(sink: sink)

        try pipeline.ingest(silentPacket(sequence: 42))
        // Notifications on the PTT control and audio characteristics have no
        // cross-characteristic ordering guarantee. A fresh session's sequence
        // zero can therefore arrive before its authenticated PTT_DOWN.
        XCTAssertNoThrow(try pipeline.ingest(silentPacket(sequence: 0)))
        pipeline.resetSession()
        try pipeline.ingest(silentPacket(sequence: 1))

        // The racing frame is deliberately discarded; after the authenticated
        // boundary the first normal audio frame must be accepted.
        XCTAssertEqual(sink.writes.count, 2)
    }

    func testExactDuplicateBleNotificationIsDroppedWithoutFailingTheSession() throws {
        let sink = RecordingFloatSink()
        let pipeline = AudioFramePipeline(sink: sink)

        try pipeline.ingest(silentPacket(sequence: 12))
        XCTAssertNoThrow(try pipeline.ingest(silentPacket(sequence: 12)))

        XCTAssertEqual(sink.writes.count, 1)
    }

    private func silentPacket(sequence: UInt16) -> Data {
        var packet = Data([
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
            0, 0, 0, 0,
        ])
        packet.append(Data(repeating: 0, count: 160))
        return packet
    }
}

private final class RecordingFloatSink: FloatAudioSink {
    var writes: [[Float]] = []
    func write(samples: [Float]) throws { writes.append(samples) }
}
