#if os(macOS)
import XCTest
@testable import CodexCompanionCore

final class WiFiAudioGatewayTests: XCTestCase {
    private let key = Data(repeating: 0x41, count: 32)
    private let sessionID: UInt64 = 0x1020
    private let source = "127.0.0.1"

    func testAuthenticatedPrebufferDrainsInSequenceAtPTTBoundary() throws {
        let sink = RecordingWiFiAudioSink()
        let gateway = makeGateway(sink: sink)
        try configure(gateway)
        try gateway.ingestForTesting(packet: packet(sequence: 1, sample: 1_000), sourceIPv4: source, at: 10.00)
        try gateway.ingestForTesting(packet: packet(sequence: 3, sample: 3_000), sourceIPv4: source, at: 10.04)
        try gateway.ingestForTesting(packet: packet(sequence: 2, sample: 2_000), sourceIPv4: source, at: 10.02)

        gateway.beginPTTForTesting(at: 10.05)
        gateway.playoutForTesting(at: 10.06)
        gateway.playoutForTesting(at: 10.08)
        gateway.playoutForTesting(at: 10.10)

        XCTAssertEqual(sink.writes.count, 3)
        XCTAssertEqual(sink.writes.map(firstPCMValue), [1_000, 2_000, 3_000])
        XCTAssertEqual(gateway.diagnosticsSnapshot().lost, 0)
    }

    func testMissingFrameInsertsExactlyOneSilentFrame() throws {
        let sink = RecordingWiFiAudioSink()
        let gateway = makeGateway(sink: sink)
        try configure(gateway)
        gateway.beginPTTForTesting(at: 20)
        try gateway.ingestForTesting(packet: packet(sequence: 10, sample: 1_000), sourceIPv4: source, at: 20.01)
        try gateway.ingestForTesting(packet: packet(sequence: 12, sample: 3_000), sourceIPv4: source, at: 20.05)
        try gateway.ingestForTesting(packet: packet(sequence: 13, sample: 4_000), sourceIPv4: source, at: 20.07)

        gateway.playoutForTesting(at: 20.08)
        gateway.playoutForTesting(at: 20.10)
        gateway.playoutForTesting(at: 20.12)

        XCTAssertEqual(sink.writes.map(firstPCMValue), [1_000, 0, 3_000])
        XCTAssertEqual(gateway.diagnosticsSnapshot().lost, 1)
    }

    func testWrongSourceReplayAndTamperAreDropped() throws {
        let sink = RecordingWiFiAudioSink()
        let gateway = makeGateway(sink: sink)
        try configure(gateway)
        let valid = try packet(sequence: 1, sample: 500)
        try gateway.ingestForTesting(packet: valid, sourceIPv4: "127.0.0.2", at: 1)
        try gateway.ingestForTesting(packet: valid, sourceIPv4: source, at: 1.01)
        try gateway.ingestForTesting(packet: valid, sourceIPv4: source, at: 1.02)
        var tampered = valid
        tampered[tampered.count - 1] ^= 1
        try gateway.ingestForTesting(packet: tampered, sourceIPv4: source, at: 1.03)

        let diagnostics = gateway.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.sourceRejected, 1)
        XCTAssertEqual(diagnostics.replayed, 1)
        XCTAssertEqual(diagnostics.authenticationFailures, 1)
        XCTAssertEqual(diagnostics.received, 1)
    }

    func testSeparatesSourceCadenceFromNetworkArrivalVariation() throws {
        let sink = RecordingWiFiAudioSink()
        let gateway = makeGateway(sink: sink)
        try configure(gateway)
        gateway.beginPTTForTesting(at: 50)
        try gateway.ingestForTesting(
            packet: packet(sequence: 1, sample: 100), sourceIPv4: source, at: 50.01
        )
        try gateway.ingestForTesting(
            packet: packet(sequence: 2, sample: 200), sourceIPv4: source, at: 50.09
        )

        let diagnostics = gateway.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.longestGapMs, 80, accuracy: 0.001)
        XCTAssertEqual(diagnostics.maximumSourceFrameIntervalMs, 20, accuracy: 0.001)
        XCTAssertEqual(diagnostics.maximumNetworkVariationMs, 60, accuracy: 0.001)
    }

    func testEmptyPlayoutDeadlineRebuffersWithoutCascadingLateFrames() throws {
        let sink = RecordingWiFiAudioSink()
        let gateway = makeGateway(sink: sink)
        try configure(gateway)
        gateway.beginPTTForTesting(at: 60)
        try gateway.ingestForTesting(packet: packet(sequence: 1, sample: 1), sourceIPv4: source, at: 60.01)
        try gateway.ingestForTesting(packet: packet(sequence: 2, sample: 2), sourceIPv4: source, at: 60.03)
        try gateway.ingestForTesting(packet: packet(sequence: 3, sample: 3), sourceIPv4: source, at: 60.05)
        gateway.playoutForTesting(at: 60.06)
        gateway.playoutForTesting(at: 60.08)
        gateway.playoutForTesting(at: 60.10)

        // With no later sequence buffered, the next deadline is jitter rather
        // than proven loss. Pause and keep sequence four eligible.
        gateway.playoutForTesting(at: 60.12)
        try gateway.ingestForTesting(packet: packet(sequence: 4, sample: 4), sourceIPv4: source, at: 60.13)
        try gateway.ingestForTesting(packet: packet(sequence: 5, sample: 5), sourceIPv4: source, at: 60.15)
        try gateway.ingestForTesting(packet: packet(sequence: 6, sample: 6), sourceIPv4: source, at: 60.17)
        gateway.playoutForTesting(at: 60.18)

        XCTAssertEqual(sink.writes.map(firstPCMValue), [1, 2, 3, 4])
        XCTAssertEqual(gateway.diagnosticsSnapshot().rebuffered, 1)
        XCTAssertEqual(gateway.diagnosticsSnapshot().lost, 0)
        XCTAssertEqual(gateway.diagnosticsSnapshot().late, 0)
    }

    func testFiveHundredMillisecondGapStaysHeldAndRecovers() throws {
        let sink = RecordingWiFiAudioSink()
        let gateway = makeGateway(sink: sink)
        try configure(gateway)
        let failed = expectation(description: "recoverable gap is not fatal")
        failed.isInverted = true
        gateway.onFatalError = { _ in failed.fulfill() }

        gateway.beginPTTForTesting(at: 30)
        gateway.playoutForTesting(at: 30.501)
        gateway.playoutForTesting(at: 31)
        try gateway.ingestForTesting(
            packet: packet(sequence: 1, sample: 100), sourceIPv4: source, at: 31.01
        )
        try gateway.ingestForTesting(
            packet: packet(sequence: 2, sample: 200), sourceIPv4: source, at: 31.03
        )
        try gateway.ingestForTesting(
            packet: packet(sequence: 3, sample: 300), sourceIPv4: source, at: 31.05
        )
        gateway.playoutForTesting(at: 31.06)

        wait(for: [failed], timeout: 0.01)
        XCTAssertEqual(gateway.diagnosticsSnapshot().recoverableStalls, 1)
        XCTAssertEqual(sink.writes.map(firstPCMValue), [100])
    }

    func testValidAuthenticatedFramePublishesActivity() throws {
        let gateway = makeGateway(sink: RecordingWiFiAudioSink())
        try configure(gateway)
        let activity = expectation(description: "authenticated UDP activity")
        gateway.onAuthenticatedActivity = { activity.fulfill() }
        try gateway.ingestForTesting(
            packet: packet(sequence: 1, sample: 100), sourceIPv4: source, at: 1
        )
        wait(for: [activity], timeout: 0.1)
    }

    func testTwoHundredMillisecondPostRollClosesBeforeStallRule() throws {
        let sink = RecordingWiFiAudioSink()
        let gateway = makeGateway(sink: sink)
        try configure(gateway)
        let failed = expectation(description: "post-roll must not become a stall")
        failed.isInverted = true
        gateway.onFatalError = { _ in failed.fulfill() }

        gateway.beginPTTForTesting(at: 40)
        gateway.endPTTForTesting(at: 40, postRollMs: 200)
        gateway.playoutForTesting(at: 40.201)
        gateway.playoutForTesting(at: 40.6)

        wait(for: [failed], timeout: 0.01)
        XCTAssertTrue(sink.writes.isEmpty)
    }

    private func makeGateway(sink: RecordingWiFiAudioSink) -> WiFiAudioGateway {
        WiFiAudioGateway(sink: sink, port: 0, automaticPlayout: false)
    }

    private func configure(_ gateway: WiFiAudioGateway) throws {
        try gateway.configure(session: WiFiAuthenticatedSession(
            sessionID: sessionID,
            audioKey: key,
            remoteIPv4: source
        ))
    }

    private func packet(sequence: UInt32, sample: Int16) throws -> Data {
        var pcm = Data()
        var littleEndian = sample.littleEndian
        let bytes = withUnsafeBytes(of: &littleEndian) { Data($0) }
        for _ in 0..<WiFiAudioFrame.sampleCount { pcm.append(bytes) }
        return try WiFiWireCodec.encodeAudio(
            WiFiAudioFrame(
                sessionID: sessionID,
                sequence: sequence,
                timestampMs: UInt64(sequence) * 20,
                pcm16LE: pcm
            ),
            key: key
        )
    }

    private func firstPCMValue(_ samples: [Float]) -> Int {
        // The first three outputs interpolate from the previous frame's final
        // sample. Index three is the first value fully owned by this frame.
        Int((samples[3] * Float(Int16.max)).rounded())
    }
}

private final class RecordingWiFiAudioSink: FloatAudioSink {
    var writes: [[Float]] = []
    func write(samples: [Float]) throws { writes.append(samples) }
}
#endif
