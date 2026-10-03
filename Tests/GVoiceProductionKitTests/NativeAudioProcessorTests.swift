import XCTest
@testable import GVoiceProductionKit

final class NativeAudioProcessorTests: XCTestCase {
    func testSliceDownmixFadeJoinAndResample() throws {
        let source = ReferenceAudioBuffer(sampleRate: 10, channels: [[0,1,2,3,4,5,6,7,8,9], [2,3,4,5,6,7,8,9,10,11]])
        let sliced = try NativeAudioProcessor.slice(source, segment: .init(startSeconds: 0.2, endSeconds: 0.6))
        XCTAssertEqual(sliced.channels[0], [2,3,4,5])
        XCTAssertEqual(NativeAudioProcessor.mono(sliced).channels[0], [3,4,5,6])
        let joined = NativeAudioProcessor.join([sliced, sliced], silenceSeconds: 0.2)
        XCTAssertEqual(joined.frameCount, 10)
        XCTAssertEqual(joined.channels[0][4...5], [0,0])
        XCTAssertEqual(try NativeAudioProcessor.resample(sliced, to: 20).frameCount, 8)
        let faded = NativeAudioProcessor.fade(sliced, inSeconds: 0.1, outSeconds: 0.2)
        XCTAssertEqual(faded.channels[0].first, 0)
        XCTAssertEqual(faded.channels[0].last, 0)
    }

    /// 18 kHz is above the 12 kHz Nyquist of a 24 kHz pack: linear interpolation would fold it back to
    /// 6 kHz at near full level; a band-limited converter removes it. Same for 44.1 kHz Demucs input.
    func testResampleAttenuatesAboveNyquistTone() throws {
        func tone(_ hz: Double, rate: Int) -> [Float] {
            (0..<(rate * 2)).map { 0.5 * sin(Float(2 * Double.pi * hz * Double($0) / Double(rate))) }
        }
        func dB(_ x: [Float]) -> Double {
            // skip the converter's start/end transients
            let body = x[(x.count / 10)..<(x.count - x.count / 10)]
            return 20 * log10(Double(rms(Array(body))) + 1e-12)
        }
        let down = try NativeAudioProcessor.resample(.init(sampleRate: 48_000, channels: [tone(18_000, rate: 48_000)]), to: 24_000)
        XCTAssertEqual(down.frameCount, 48_000)
        let inLevel = dB(tone(18_000, rate: 48_000))
        XCTAssertLessThan(dB(down.channels[0]), inLevel - 40, "18 kHz tone must be attenuated > 40 dB at 24 kHz")
        // an in-band tone passes at full level and keeps its length
        let pass = try NativeAudioProcessor.resample(.init(sampleRate: 48_000, channels: [tone(1_000, rate: 48_000)]), to: 24_000)
        XCTAssertEqual(dB(pass.channels[0]), dB(tone(1_000, rate: 48_000)), accuracy: 0.5)
        let up = try NativeAudioProcessor.resample(.init(sampleRate: 48_000, channels: [tone(1_000, rate: 48_000)]), to: 44_100)
        XCTAssertEqual(up.frameCount, 88_200)
        XCTAssertEqual(dB(up.channels[0]), dB(tone(1_000, rate: 48_000)), accuracy: 0.5)
    }

    func testFiltersRejectOutOfBandToneAndDenoiseReducesQuietFloor() throws {
        let rate = 48_000
        func tone(_ hz: Double, amplitude: Float) -> [Float] {
            (0..<rate).map { amplitude * sin(Float(2 * Double.pi * hz * Double($0) / Double(rate))) }
        }
        let low = ReferenceAudioBuffer(sampleRate: rate, channels: [tone(20, amplitude: 0.5)])
        let high = ReferenceAudioBuffer(sampleRate: rate, channels: [tone(18_000, amplitude: 0.5)])
        XCTAssertLessThan(rms(NativeAudioProcessor.bandLimit(low, highpassHz: 70, lowpassHz: 15_000).channels[0]), 0.2)
        XCTAssertLessThan(rms(NativeAudioProcessor.bandLimit(high, highpassHz: 70, lowpassHz: 15_000).channels[0]), 0.2)
        let quiet = ReferenceAudioBuffer(sampleRate: rate, channels: [[Float](repeating: 0.005, count: 2048)])
        XCTAssertLessThan(rms(NativeAudioProcessor.denoise(quiet, strength: .light).channels[0]), rms(quiet.channels[0]))
    }

    func testPCM16WAVAndLimits() throws {
        let audio = ReferenceAudioBuffer(sampleRate: 24_000, channels: [[0, 0.5, -0.5]])
        let data = try NativeAudioProcessor.pcm16WAV(audio)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 50)
        XCTAssertThrowsError(try NativeAudioProcessor.validateAllocation(sampleRate: 48_000, channels: 2, duration: 3_601))
    }

    private func rms(_ values: [Float]) -> Float {
        sqrt(values.reduce(0) { $0 + $1 * $1 } / Float(max(1, values.count)))
    }
}
