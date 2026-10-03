import AVFoundation
import Foundation

public enum NativeAudioProcessor {
    public static let maximumDurationSeconds = 3_600.0
    public static let maximumSamples = 48_000 * 2 * 3_600

    public static func validateAllocation(sampleRate: Int, channels: Int, duration: Double) throws {
        guard sampleRate > 0, channels > 0, duration.isFinite, duration >= 0,
              duration <= maximumDurationSeconds,
              Double(sampleRate) * Double(channels) * duration <= Double(maximumSamples) else {
            throw ReferencePreparationError.invalidRecipe("audio exceeds native processing limits")
        }
    }

    public static func decode(_ url: URL) throws -> ReferenceAudioBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        try validateAllocation(sampleRate: Int(format.sampleRate.rounded()), channels: Int(format.channelCount), duration: duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ReferencePreparationError.unreadableSource("cannot allocate audio buffer")
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        let count = Int(format.channelCount)
        guard let data = buffer.floatChannelData else {
            throw ReferencePreparationError.unreadableSource("audio could not be decoded as float PCM")
        }
        return .init(sampleRate: Int(format.sampleRate.rounded()),
                     channels: (0..<count).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) })
    }

    public static func slice(_ input: ReferenceAudioBuffer, segment: ReferenceSegment) throws -> ReferenceAudioBuffer {
        let start = Int((segment.startSeconds * Double(input.sampleRate)).rounded())
        let end = Int((segment.endSeconds * Double(input.sampleRate)).rounded())
        guard start >= 0, end > start, end <= input.frameCount else {
            throw ReferencePreparationError.invalidSegment(index: 0, reason: "outside decoded audio")
        }
        return .init(sampleRate: input.sampleRate, channels: input.channels.map { Array($0[start..<end]) })
    }

    public static func mono(_ input: ReferenceAudioBuffer) -> ReferenceAudioBuffer {
        guard input.channelCount > 1 else { return input }
        var output = [Float](repeating: 0, count: input.frameCount)
        for channel in input.channels { for i in output.indices { output[i] += channel[i] } }
        let scale = 1 / Float(input.channelCount)
        for i in output.indices { output[i] *= scale }
        return .init(sampleRate: input.sampleRate, channels: [output])
    }

    public static func fade(_ input: ReferenceAudioBuffer, inSeconds: Double, outSeconds: Double) -> ReferenceAudioBuffer {
        var output = input
        let fadeIn = min(input.frameCount / 2, max(0, Int(inSeconds * Double(input.sampleRate))))
        let fadeOut = min(input.frameCount / 2, max(0, Int(outSeconds * Double(input.sampleRate))))
        for c in output.channels.indices {
            if fadeIn > 0 { for i in 0..<fadeIn { output.channels[c][i] *= Float(i) / Float(fadeIn) } }
            if fadeOut > 0 { for i in 0..<fadeOut { output.channels[c][input.frameCount - 1 - i] *= Float(i) / Float(fadeOut) } }
        }
        return output
    }

    public static func join(_ inputs: [ReferenceAudioBuffer], silenceSeconds: Double) -> ReferenceAudioBuffer {
        guard let first = inputs.first else { return .init(sampleRate: 24_000, channels: [[]]) }
        let silence = [Float](repeating: 0, count: max(0, Int(silenceSeconds * Double(first.sampleRate))))
        var channels = [[Float]](repeating: [], count: first.channelCount)
        for (index, input) in inputs.enumerated() {
            precondition(input.sampleRate == first.sampleRate && input.channelCount == first.channelCount)
            for c in channels.indices {
                if index > 0 { channels[c].append(contentsOf: silence) }
                channels[c].append(contentsOf: input.channels[c])
            }
        }
        return .init(sampleRate: first.sampleRate, channels: channels)
    }

    public static func bandLimit(_ input: ReferenceAudioBuffer, highpassHz: Double, lowpassHz: Double) -> ReferenceAudioBuffer {
        var output = input
        for c in output.channels.indices {
            var samples = output.channels[c]
            samples = highpass(highpass(samples, cutoff: highpassHz, rate: Double(input.sampleRate)), cutoff: highpassHz, rate: Double(input.sampleRate))
            samples = lowpass(lowpass(samples, cutoff: lowpassHz, rate: Double(input.sampleRate)), cutoff: lowpassHz, rate: Double(input.sampleRate))
            output.channels[c] = samples
        }
        return output
    }

    public static func denoise(_ input: ReferenceAudioBuffer, strength: ReferenceDenoise) -> ReferenceAudioBuffer {
        guard strength != .none else { return input }
        let threshold: Float = strength == .light ? 0.012 : 0.025
        let floor: Float = strength == .light ? 0.25 : 0.08
        var output = input
        for c in output.channels.indices {
            output.channels[c] = output.channels[c].map { sample in
                let magnitude = abs(sample)
                guard magnitude < threshold else { return sample }
                let blend = magnitude / threshold
                return sample * (floor + (1 - floor) * blend)
            }
        }
        return output
    }

    public static func resample(_ input: ReferenceAudioBuffer, to rate: Int) throws -> ReferenceAudioBuffer {
        guard rate > 0 else { throw ReferencePreparationError.invalidRecipe("sample rate must be positive") }
        guard rate != input.sampleRate else { return input }
        let count = Int((Double(input.frameCount) * Double(rate) / Double(input.sampleRate)).rounded())
        let channels = input.channels.map { source -> [Float] in
            guard count > 1, source.count > 1 else { return Array(source.prefix(count)) }
            return (0..<count).map { i in
                let position = Double(i) * Double(source.count - 1) / Double(count - 1)
                let lower = Int(position), upper = min(source.count - 1, lower + 1)
                let fraction = Float(position - Double(lower))
                return source[lower] * (1 - fraction) + source[upper] * fraction
            }
        }
        return .init(sampleRate: rate, channels: channels)
    }

    public static func pcm16WAV(_ input: ReferenceAudioBuffer) throws -> Data {
        guard input.sampleRate > 0, !input.channels.isEmpty,
              input.channels.allSatisfy({ $0.count == input.frameCount }) else {
            throw ReferencePreparationError.invalidRecipe("invalid audio buffer")
        }
        let channels = input.channelCount, bytes = input.frameCount * channels * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: Int) { var v = UInt16(value).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + bytes); text("WAVEfmt "); u32(16); u16(1); u16(channels)
        u32(input.sampleRate); u32(input.sampleRate * channels * 2); u16(channels * 2); u16(16)
        text("data"); u32(bytes)
        for frame in 0..<input.frameCount { for channel in 0..<channels {
            var value = Int16((max(-1, min(1, input.channels[channel][frame])) * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }}
        return data
    }

    private static func lowpass(_ x: [Float], cutoff: Double, rate: Double) -> [Float] {
        guard !x.isEmpty else { return [] }
        let dt = 1 / rate, rc = 1 / (2 * Double.pi * cutoff), a = Float(dt / (rc + dt))
        var y = x, last = x[0]
        for i in x.indices { last += a * (x[i] - last); y[i] = last }
        return y
    }
    private static func highpass(_ x: [Float], cutoff: Double, rate: Double) -> [Float] {
        guard !x.isEmpty else { return [] }
        let dt = 1 / rate, rc = 1 / (2 * Double.pi * cutoff), a = Float(rc / (rc + dt))
        var y = x, lastY: Float = 0, lastX = x[0]
        for i in x.indices { let next = a * (lastY + x[i] - lastX); y[i] = next; lastY = next; lastX = x[i] }
        return y
    }
}
