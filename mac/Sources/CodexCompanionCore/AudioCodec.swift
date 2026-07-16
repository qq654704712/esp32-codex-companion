import Foundation

public struct DecodedAudioFrame: Equatable, Sendable {
    public let sequence: UInt16
    public let samples: [Int16]
}

public enum AudioCodecError: Error, Equatable {
    case invalidFrameLength
    case invalidStepIndex
    case replayedFrame
    case frameGapTooLarge
}

public enum ADPCMFrameCodec {
    public static let encodedFrameLength = 166
    public static let samplesPerFrame = 320

    public static func decode(_ data: Data) throws -> DecodedAudioFrame {
        guard data.count == encodedFrameLength else {
            throw AudioCodecError.invalidFrameLength
        }
        let sequence = UInt16(data[0]) << 8 | UInt16(data[1])
        var predictor = Int(Int16(bitPattern: UInt16(data[2]) << 8 | UInt16(data[3])))
        var stepIndex = Int(data[4])
        guard stepTable.indices.contains(stepIndex) else {
            throw AudioCodecError.invalidStepIndex
        }
        var samples: [Int16] = []
        samples.reserveCapacity(samplesPerFrame)
        for byte in data.dropFirst(6) {
            decodeNibble(Int(byte & 0x0F), predictor: &predictor, stepIndex: &stepIndex, into: &samples)
            decodeNibble(Int(byte >> 4), predictor: &predictor, stepIndex: &stepIndex, into: &samples)
        }
        return DecodedAudioFrame(sequence: sequence, samples: samples)
    }

    private static func decodeNibble(
        _ nibble: Int,
        predictor: inout Int,
        stepIndex: inout Int,
        into samples: inout [Int16]
    ) {
        let step = stepTable[stepIndex]
        var difference = step >> 3
        if nibble & 1 != 0 { difference += step >> 2 }
        if nibble & 2 != 0 { difference += step >> 1 }
        if nibble & 4 != 0 { difference += step }
        predictor += nibble & 8 == 0 ? difference : -difference
        predictor = min(Int(Int16.max), max(Int(Int16.min), predictor))
        stepIndex += indexTable[nibble & 7]
        stepIndex = min(stepTable.count - 1, max(0, stepIndex))
        samples.append(Int16(predictor))
    }

    private static let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8]
    private static let stepTable = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
        143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
        494, 544, 598, 658, 724, 796, 876, 963, 1_060, 1_166, 1_282,
        1_411, 1_552, 1_707, 1_878, 2_066, 2_272, 2_499, 2_749, 3_024,
        3_327, 3_660, 4_026, 4_428, 4_871, 5_358, 5_894, 6_484, 7_132,
        7_845, 8_630, 9_493, 10_442, 11_487, 12_635, 13_899, 15_289,
        16_818, 18_500, 20_350, 22_385, 24_623, 27_086, 29_794, 32_767,
    ]
}

public struct AudioFrameSequencer: Sendable {
    private let samplesPerFrame: Int
    private let maximumConcealedFrames: UInt16
    private var lastSequence: UInt16?

    public init(samplesPerFrame: Int, maximumConcealedFrames: UInt16 = 10) {
        self.samplesPerFrame = samplesPerFrame
        self.maximumConcealedFrames = maximumConcealedFrames
    }

    public var lastAcceptedSequence: UInt16? { lastSequence }

    public mutating func accept(sequence: UInt16) throws -> [Int16] {
        guard let lastSequence else {
            self.lastSequence = sequence
            return []
        }
        let expected = lastSequence &+ 1
        let missing = sequence &- expected
        guard missing < 0x8000 else { throw AudioCodecError.replayedFrame }
        guard missing <= maximumConcealedFrames else {
            throw AudioCodecError.frameGapTooLarge
        }
        self.lastSequence = sequence
        return [Int16](repeating: 0, count: Int(missing) * samplesPerFrame)
    }
}

public struct LinearResampler16kTo48k: Sendable {
    private var previous: Int16?

    public init() {}

    public mutating func process(_ input: [Int16]) -> [Float] {
        guard !input.isEmpty else { return [] }
        var output: [Float] = []
        output.reserveCapacity(input.count * 3)
        for sample in input {
            let start = Float(previous ?? sample)
            let end = Float(sample)
            output.append(normalize(start))
            output.append(normalize(start + (end - start) / 3))
            output.append(normalize(start + 2 * (end - start) / 3))
            previous = sample
        }
        return output
    }

    private func normalize(_ sample: Float) -> Float {
        sample / Float(Int16.max)
    }
}
