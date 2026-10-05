import Accelerate
import AVFoundation
import Combine
import Foundation

/// Live microphone recorder for the Clone Studio. Streams the mic to a temp WAV
/// and publishes a rolling amplitude envelope so the UI can draw a reactive
/// waveform while you speak. Reuses `VoiceAudio.loadWav24k` downstream for the
/// speaker encoder, so no resampling logic lives here.
@MainActor
public final class CloneRecorder: ObservableObject {
    @Published public var isRecording = false
    @Published public var level: Float = 0          // current amplitude, 0…1
    @Published public var levels: [Float] = []      // rolling history (newest last)
    @Published public var elapsed: Double = 0       // seconds recorded
    @Published public var denied = false

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var startAt: Date?
    public private(set) var lastURL: URL?
    /// Where this recorder writes. The clone flow's durable file by default;
    /// a take recorder gets its own, so recording a take can neither wipe an
    /// interrupted clone nor be offered as one to resume.
    public let url: URL

    public init(url: URL = CloneRecorder.recURL) { self.url = url }

    /// Durable (Documents, not temp) so an interrupted clone — e.g. a mid-render
    /// crash — doesn't lose the take; Clone Studio can offer to resume it.
    public static let recURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("clone_rec.caf")

    /// A recording exists on disk that hasn't been turned into a saved clone yet.
    public static var hasPending: Bool { FileManager.default.fileExists(atPath: recURL.path) }
    /// Call after a clone is saved (or discarded) so it's no longer offered to resume.
    public static func clearPending() { try? FileManager.default.removeItem(at: recURL) }

    /// Ask for mic permission up front so the first tap records instantly.
    public func prewarm() {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            AVAudioApplication.requestRecordPermission { _ in }
        }
    }

    public func start() {
        guard !isRecording else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .denied: denied = true; return
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in granted ? self?.start() : (self?.denied = true) }
            }
            return
        default: break
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try? session.setActive(true)
        #endif

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        try? FileManager.default.removeItem(at: url)
        file = try? AVAudioFile(forWriting: url, settings: fmt.settings)
        lastURL = url
        levels = []; level = 0; elapsed = 0; startAt = Date(); denied = false

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            try? self?.file?.write(from: buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            vDSP_measqv(ch, 1, &sum, vDSP_Length(n))       // mean square
            let rms = sqrtf(sum)
            Task { @MainActor in self?.push(rms) }
        }
        engine.prepare()
        do { try engine.start() } catch { NSLog("[rec] \(error.localizedDescription)"); return }
        isRecording = true
    }

    private func push(_ rms: Float) {
        level = min(1, rms * 6)
        levels.append(level)
        if levels.count > 64 { levels.removeFirst() }
        if let s = startAt { elapsed = Date().timeIntervalSince(s) }
    }

    public func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        isRecording = false
    }
}
