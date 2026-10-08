import AVFoundation

/// Apple's Voice Isolation (AUSoundIsolation, the effect behind Final Cut's
/// Voice Isolation), run offline. Shared by every app that records a clone
/// reference (Studio iOS/macOS, the radio apps) so they clean a take the same
/// way; moved here from gloam-voice-studio-ios/App/Cleanup (2026-10-07). On iOS 18 it has a "High
/// Quality Voice" mode, which this uses: it takes out room noise AND room
/// tone, the two things a clone copies from a phone recording.
///
/// Measured on David's phone references against the bundled DPDFNet
/// (cleanup-lab, 2026-10-06; Qwen 0.6B clones, n=8, similarity anchored on a
/// clean reference no candidate touched): untouched noisy 0.802, HQ Voice at
/// 100% wet 0.797 (it hard-gates the pauses and the clone inherits the
/// gating), HQ Voice with the dry signal back at -20 dB 0.843, DPDFNet with
/// -18 dB dry 0.840. So this returns the fully isolated voice and lets
/// `NoiseCleanup.clean` mix the original back at -18 dB, as for DPDFNet: the
/// pauses keep a natural floor and the clone has no gated silences to learn.
public final class AppleVoiceIsolation: SpeechDenoiser, @unchecked Sendable {
    public init() {}
    public let name = "apple-voice-isolation-hq"

    public static let component = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// Whether this device has the unit (it ships with iOS 16+; HQ Voice is iOS 18+).
    /// The High Quality Voice mode this relies on is macOS 15 / iOS 18; the older Voice mode measured worse
    /// than DPDFNet, so an older system counts as "not available" and the app's fallback cleans instead.
    public static var isAvailable: Bool {
        guard #available(macOS 15.0, iOS 18.0, *) else { return false }
        var desc = component
        return AudioComponentFindNext(nil, &desc) != nil
    }

    public func denoise(_ samples24k: [Float]) async throws -> [Float] {
        try Self.isolate(samples24k, sampleRate: 24000)
    }

    /// The isolated signal, sample-aligned with `input` and exactly as long:
    /// the unit's latency is rendered past and dropped from the front.
    public static func isolate(_ input: [Float], sampleRate: Double) throws -> [Float] {
        guard !input.isEmpty else { return [] }
        guard isAvailable else { throw IsolationError.unavailable }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count))
        else { throw IsolationError.failed("format") }
        source.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: input.count) }

        let engine = AVAudioEngine()
        // Offline BEFORE anything touches the graph: mainMixerNode would
        // otherwise build the hardware output (RemoteIO), and its RPC to the
        // audio server can time out -- Core Audio then aborts the app
        // ("Cleanup: RPC timeout. Apparently deadlocked", 2026-10-06, Simulator).
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let player = AVAudioPlayerNode()
        let unit = AVAudioUnitEffect(audioComponentDescription: component)
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        try configure(unit.auAudioUnit)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(source, at: nil)
        player.play()

        let latency = Int((unit.auAudioUnit.latency * sampleRate).rounded())
        let wanted = input.count + latency
        guard let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                           frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw IsolationError.failed("buffer") }
        var out: [Float] = []
        out.reserveCapacity(wanted)
        while out.count < wanted {
            let n = AVAudioFrameCount(min(Int(chunk.frameCapacity), wanted - out.count))
            // .cannotDoInCurrentContext is documented as "try again"; anything else is fatal.
            var status = try engine.renderOffline(n, to: chunk)
            if status == .cannotDoInCurrentContext { status = try engine.renderOffline(n, to: chunk) }
            guard status == .success else { throw IsolationError.failed("render \(status.rawValue)") }
            out.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength)))
        }
        return Array(out[latency ..< latency + input.count])
    }

    /// Fully wet, High Quality Voice -- and proof that both took. A unit that
    /// ignored the mode would quietly run the older Voice mode, which measured
    /// worse than DPDFNet (-1.3 dB speech, -2.6 dB highs); throwing instead
    /// leaves the take uncleaned, the qualifier's normal "original only" path.
    public static func configure(_ au: AUAudioUnit) throws {
        guard #available(macOS 15.0, iOS 18.0, *) else { throw IsolationError.unavailable }
        guard let tree = au.parameterTree,
              let mix = tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent)),
              let mode = tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))
        else { throw IsolationError.failed("parameters") }
        mix.value = 100
        mode.value = Float(kAUSoundIsolationSoundType_HighQualityVoice)
        guard mix.value == 100, mode.value == Float(kAUSoundIsolationSoundType_HighQualityVoice)
        else { throw IsolationError.failed("High Quality Voice not supported") }
    }

    public enum IsolationError: LocalizedError {
        case unavailable
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable: "Voice isolation isn't available on this device."
            case .failed(let step): "Voice isolation failed (\(step))."
            }
        }
    }
}
