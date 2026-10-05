import AVFoundation
import Foundation
import GVoiceKit

/// The steady noise under a voice's reference, and the floors that follow
/// from it.
///
/// Every level check in the render path assumes silence sits below -45 dB
/// (speech floor) or -35 dB (the fork's trailing-silence stop). Morgan
/// Freeman's reference does not: its 10th-percentile 50 ms level is -35 dB,
/// 98% of its blocks count as voiced, and Qwen copies the bed into its
/// renders: a tail of pure bed never reads as quiet to the trailing stop
/// (7 of 30 Mac renders ran to the token cap, Jeff 0 of 10; a floor over the
/// bed ended 2 of those 7 on time, the other 5 keep talking), and a render of
/// pure bed passes as speech.
///
/// So the bed is measured from the reference the render clones from, and
/// the floors are set a margin above it. A clean reference leaves every
/// floor exactly where it was.
///
/// Ported from the iPhone app (0959ff6, 3bbb3aa): the speech floor feeds
/// `RenderCheck.signal`; the trailing floor and reference gain are for a
/// host's Qwen engine.
public enum NoiseBed {
    /// The reference's level at this fraction of its sorted 50 ms blocks. The
    /// 5th percentile (RecordingCheck) is one pause away from the true bed in
    /// a short clip; the 10th sits in the bed for any clip with pauses, and
    /// on a bedded clip sits in the bed itself.
    public static let percentile = 0.10
    /// At or above this floor the reference is bedded. Real references, 10th
    /// percentile (2026-10-02): Morgan -35.0; Cruz -47.3, Jeff -48.5, Billie
    /// -57, Benson -64. The line sits 7 dB from each side, so ordinary room
    /// tone never moves a clean voice's floors.
    public static let bedAboveDb: Float = -42
    /// Over the bed. Morgan's own pauses never exceed 0.94 s below bed + 6
    /// (the stop wants 1.5 s of quiet, which a bed-level tail supplies), and
    /// speech blocks sit 15-20 dB above it. Trailing floors of -32, -29 and
    /// -26 (margins 3, 6, 9) gave identical Mac renders; 6 is the middle.
    public static let marginDb: Float = 6
    /// The fork's trailing-silence floor, `Qwen3TTSModel.trailingSilenceFloorDb`.
    public static let defaultTrailingFloorDb: Float = -35

    public static func isBedded(_ noiseFloorDb: Float?) -> Bool {
        guard let noiseFloorDb else { return false }
        return noiseFloorDb >= bedAboveDb
    }

    /// The bed as it comes out in a render: Qwen follows the level it is given,
    /// so the reference's bed less the gain it was turned down by. (Floors off
    /// the raw reference sat 2 dB high against a render of the turned-down
    /// clip: 2 of 60 renders were cut mid-sentence by the trailing stop.)
    private static func bedInRendersDb(_ noiseFloorDb: Float) -> Float {
        noiseFloorDb + referenceGainDb(noiseFloorDb: noiseFloorDb)
    }

    /// Where speech starts, for RenderCheck's hiss test and LeadingSilenceGate.
    public static func speechFloorDb(noiseFloorDb: Float?) -> Float {
        guard let noiseFloorDb, isBedded(noiseFloorDb) else { return RenderCheck.speechFloorDb }
        return bedInRendersDb(noiseFloorDb) + marginDb
    }

    /// Where the fork's trailing-silence stop calls the tail quiet. Never
    /// lower than the fork's own -35.
    public static func trailingFloorDb(noiseFloorDb: Float?) -> Float {
        guard let noiseFloorDb, isBedded(noiseFloorDb) else { return defaultTrailingFloorDb }
        return max(defaultTrailingFloorDb, bedInRendersDb(noiseFloorDb) + marginDb)
    }

    /// Gain on the clip Qwen clones from. Qwen follows the level of what it
    /// is given, and Morgan's renders peak at 0.97 on average (Jeff 0.88):
    /// the decoder hard-clips at +-1 and 14 of 30 Mac renders clipped (6 over
    /// RenderCheck's 0.1%, max 0.73%; the phone reached 3.9%). The same 30
    /// seeds from a clip turned down, 2026-10-02 (`docs/calibration`):
    ///   gain   renders over 0.1%   mean level   mean peak
    ///    0 dB          6 / 30       -16.3 dB       0.97
    ///   -2 dB          0 / 30       -19.4 dB       0.89   (worst 0.07%)
    ///   -3 dB          1 / 30       -21.5 dB       0.79
    ///   -4 dB          0 / 30       -25.2 dB       0.66
    ///   -6 dB          0 / 30       -23.2 dB       0.61
    /// -2 is the least that clears the flag, and keeps Morgan inside the
    /// level range of the clean voices (-16.9 Jeff ... -21.5 Cruz). One
    /// voice measured, so only a bedded reference is touched.
    public static let beddedReferenceGainDb: Float = -2

    public static func referenceGainDb(noiseFloorDb: Float?) -> Float {
        isBedded(noiseFloorDb) ? beddedReferenceGainDb : 0
    }

    /// 10th-percentile 50 ms block level in dBFS; -120 for nothing.
    public static func floorDb(of samples: [Float], sampleRate: Int) -> Float {
        let block = max(1, sampleRate / 20)
        var levels: [Float] = []
        var i = 0
        while i + block <= samples.count {
            var acc: Float = 0
            for s in samples[i..<(i + block)] { acc += s * s }
            let rms = (acc / Float(block)).squareRoot()
            levels.append(rms > 1e-6 ? 20 * log10(rms) : -120)
            i += block
        }
        guard !levels.isEmpty else { return -120 }
        levels.sort()
        return levels[min(levels.count - 1, Int(Double(levels.count) * percentile))]
    }

    /// THE measurement of a reference's bed, used by the engine (which sets
    /// the trailing floor from it) and by RenderGuard (the speech floor), so
    /// the two can never disagree about the -42 dB line: the clip as Qwen
    /// clones from it, i.e. without the tail `ReferenceTail` cuts off.
    /// Cached by file and modification date (the editor rewrites ref.wav in
    /// place); nil when the file cannot be read. Decodes the clip, so call it
    /// off the path to first sound.
    public static func floorDb(of url: URL) -> Float? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        let key = Key(path: url.path, modified: modified)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData
        else { return nil }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        let rate = Int(file.processingFormat.sampleRate)
        let end = ReferenceTail.end(of: samples, sampleRate: rate)
        let floor = floorDb(of: Array(samples[0 ..< min(end, samples.count)]), sampleRate: rate)
        cache.withLock { $0[key] = floor }
        return floor
    }

    private struct Key: Hashable { let path: String; let modified: Date }
    private static let cache = NSLockedBox<[Key: Float]>([:])
}

/// A value behind a lock; `NSLock` has no generic wrapper in the SDK this builds on.
private final class NSLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
