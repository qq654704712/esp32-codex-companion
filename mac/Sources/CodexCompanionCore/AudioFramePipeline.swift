import Foundation
#if os(macOS)
import OSLog
#endif

public protocol FloatAudioSink: AnyObject {
    func write(samples: [Float]) throws
}

public final class AudioFramePipeline {
    private let sink: FloatAudioSink
    private var sequencer = AudioFrameSequencer(samplesPerFrame: ADPCMFrameCodec.samplesPerFrame)
    private var resampler = LinearResampler16kTo48k()
    private var awaitingAuthenticatedSessionBoundary = false
    private var sessionGeneration = 0
    private var acceptedFramesInSession = 0
#if os(macOS)
    private let diagnostics = Logger(subsystem: "com.codexcompanion.app", category: "voice-frame-order")
#endif

    public init(sink: FloatAudioSink) {
        self.sink = sink
    }

    public func ingest(_ packet: Data) throws {
        let frame = try ADPCMFrameCodec.decode(packet)
        // A control notification and an audio notification use separate BLE
        // characteristics. Even if the ESP32 sends PTT_DOWN first, CoreBluetooth
        // is allowed to deliver the fresh session's sequence-zero audio first.
        // Do not mistake that legal ordering for a replay; discard only the
        // short pre-boundary slice until authenticated PTT_DOWN resets us.
        if awaitingAuthenticatedSessionBoundary {
#if os(macOS)
            diagnostics.notice("drop awaiting-boundary generation=\(self.sessionGeneration, privacy: .public) sequence=\(frame.sequence, privacy: .public)")
#endif
            return
        }
        // GATT notifications are not acknowledged. CoreBluetooth can surface
        // the same notification more than once; an exact duplicate carries no
        // new samples and must not end an otherwise healthy PTT session.
        if frame.sequence == sequencer.lastAcceptedSequence {
#if os(macOS)
            diagnostics.notice("drop duplicate generation=\(self.sessionGeneration, privacy: .public) sequence=\(frame.sequence, privacy: .public)")
#endif
            return
        }
        let concealed: [Int16]
        do {
            concealed = try sequencer.accept(sequence: frame.sequence)
        } catch AudioCodecError.replayedFrame where frame.sequence == 0 {
            awaitingAuthenticatedSessionBoundary = true
#if os(macOS)
            diagnostics.error("sequence-zero replay generation=\(self.sessionGeneration, privacy: .public) previous=\(self.sequencer.lastAcceptedSequence ?? UInt16.max, privacy: .public); waiting for PTT_DOWN")
#endif
            return
        } catch {
#if os(macOS)
            diagnostics.error("audio reject generation=\(self.sessionGeneration, privacy: .public) sequence=\(frame.sequence, privacy: .public) previous=\(self.sequencer.lastAcceptedSequence ?? UInt16.max, privacy: .public) error=\(String(describing: error), privacy: .public)")
#endif
            throw error
        }
#if os(macOS)
        if acceptedFramesInSession < 5 {
            diagnostics.notice("audio accept generation=\(self.sessionGeneration, privacy: .public) sequence=\(frame.sequence, privacy: .public) previous=\(self.sequencer.lastAcceptedSequence ?? UInt16.max, privacy: .public)")
        }
#endif
        acceptedFramesInSession += 1
        let combined = concealed + frame.samples
        try sink.write(samples: resampler.process(combined))
    }

    /// The ESP32 restarts its 16-bit sequence at the beginning of each
    /// push-to-talk stream. This is called only from authenticated PTT_DOWN
    /// control handling, so a repeated audio packet cannot reset validation.
    public func resetSession() {
        sessionGeneration &+= 1
        acceptedFramesInSession = 0
        awaitingAuthenticatedSessionBoundary = false
        sequencer = AudioFrameSequencer(samplesPerFrame: ADPCMFrameCodec.samplesPerFrame)
        resampler = LinearResampler16kTo48k()
#if os(macOS)
        diagnostics.notice("PTT_DOWN reset generation=\(self.sessionGeneration, privacy: .public)")
#endif
    }
}
